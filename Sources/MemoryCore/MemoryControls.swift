import Foundation

/// What a delete or a correction acts on. `kind`:
/// - "action": one action (`id`);
/// - "activity": one moment (`id`, on `day` in `timezone`);
/// - "day": every action of `day` in `timezone`;
/// - "range" (Forget a time range): every stored action whose time `t` satisfies `start <= t < end`, where `start` and
///   `end` are ISO 8601 instants (any offset; a range may cross local midnight, days and time zones). The range is
///   half open: an action exactly at `start` is in it, one exactly at `end` is not, so two ranges that meet never
///   share an action. It is cut by action, never by moment: a moment that crosses an edge loses only its in-range
///   actions, and its note is deleted (it cited them) and written again from what is left. `timezone` only names the
///   local days the preview counts moments in and the times it shows; it never moves the range.
public struct MemoryActionScope:Codable,Equatable {
    public var kind:String
    public var id:String?
    public var day:String?
    public var timezone:String?
    /// kind "range" only: the instants the range starts at (in it) and ends at (not in it).
    public var start:String?
    public var end:String?
    public init(kind:String,id:String?=nil,day:String?=nil,timezone:String?=nil,start:String?=nil,end:String?=nil) {
        self.kind=kind; self.id=id; self.day=day; self.timezone=timezone; self.start=start; self.end=end
    }
    /// A "range" scope from `start` (in it) to `end` (not in it), kept to the millisecond the store's times use.
    public static func range(start:Date,end:Date,timezone:String) -> MemoryActionScope {
        MemoryActionScope(kind:"range",timezone:timezone,start:MemoryStore.actionBound(start),end:MemoryStore.actionBound(end))
    }
    /// Longest range one Forget takes, and the most actions it removes at once.
    public static let rangeLimit:TimeInterval=400*86400
    public static let rangeActionLimit=100_000
}
public struct DeletionPreview:Codable {
    public var id:String
    public var scope:MemoryActionScope
    public var actionIDs:[String]
    public var actionCount:Int
    public var revision:String
    public var expiresAt:String
    public var warning:String
    /// kind "range": the moments with at least one action in the range (moments that cross an edge count; nil when the
    /// range is too long to assemble its days for a count), the exact range, and a mark of every in-range action's
    /// revision (the commit refuses when any of them changed).
    public var momentCount:Int?
    public var rangeStart:String?
    public var rangeEnd:String?
    public var scopeRevision:String?
    /// kind "range" with no saved actions left (history retention took them): the frozen day, week and month summaries
    /// that span it, which the Forget deletes (r1 forget-range). nil otherwise.
    public var summaryCount:Int?
    public init(id:String,scope:MemoryActionScope,actionIDs:[String],actionCount:Int,revision:String,expiresAt:String,warning:String,
                momentCount:Int?=nil,rangeStart:String?=nil,rangeEnd:String?=nil,scopeRevision:String?=nil,summaryCount:Int?=nil) {
        self.id=id; self.scope=scope; self.actionIDs=actionIDs; self.actionCount=actionCount; self.revision=revision; self.expiresAt=expiresAt
        self.warning=warning; self.momentCount=momentCount; self.rangeStart=rangeStart; self.rangeEnd=rangeEnd; self.scopeRevision=scopeRevision
        self.summaryCount=summaryCount
    }
    /// A range with no saved actions: nothing to forget, no preview.
    public static let nothingInRange="Nothing saved in that range."
    /// The range forget's edge rule, in the preview's words.
    public static let rangeEdges="Moments that cross the edges keep what's outside the range."
    /// The tail of a moment's or an action's forget alert: what deleting here can't reach (PRIVACY.md,
    /// "Hide and delete"), in plain words.
    public static let notRecalled="Backups, exported copies, and anything AI apps or cloud summaries already got aren't deleted."
}
public struct DeletionReceipt:Codable {
    public var previewID:String
    public var actionIDs:[String]
    public var deletedAt:String
    public var deletionRevision:String
    public var attachmentCleanup:String
    public var searchCleanup:String
}
public struct UserCorrection:Codable,Equatable {
    public var targetKind:String
    public var targetID:String
    public var version:Int
    public var text:String?
    public var actionIDs:[String]
    public var authoredAt:String
    public var attribution:String = "User correction, not observed evidence"
}
extension MemoryStore {
    func setupMemoryControls() throws {
        try exec("CREATE TABLE IF NOT EXISTS user_corrections(kind TEXT NOT NULL,target TEXT NOT NULL,version INTEGER NOT NULL,body TEXT NOT NULL,PRIMARY KEY(kind,target,version))")
        try exec("CREATE TABLE IF NOT EXISTS deletion_previews(id TEXT PRIMARY KEY,body TEXT NOT NULL,state TEXT NOT NULL,receipt TEXT)")
        // Read first: a store that has its ID needs no write lock to open, so an open never waits on (or fails
        // behind) a long write on another connection. OR IGNORE still settles two first opens racing.
        if try rows("SELECT 1 FROM metadata WHERE id='core_store_id'").isEmpty {
            try exec("INSERT OR IGNORE INTO metadata VALUES('core_store_id',?)",[UUID().uuidString])
        }
    }
    func hasMemoryControls() throws -> Bool { !(try rows("SELECT name FROM sqlite_master WHERE name='user_corrections'")).isEmpty }
    func scopeActions(_ scope:MemoryActionScope,now:Date) throws -> (ids:[String],revision:String) {
        if scope.kind == "action" {
            guard let id=scope.id, let action=try action(id,now:now) else { throw MemError.invalid("Action unavailable under current policy") }
            return ([id],action.revision)
        }
        if scope.kind == "range" { return try rangeActions(scope) }
        guard ["activity","day"].contains(scope.kind), let day=scope.day, let zone=scope.timezone else { throw MemError.invalid("Exact activity or whole-day scope required") }
        let layers=try dayLayers(day:day,timezone:zone,now:now)
        // No partial scope may be advertised as an entire activity/day.
        guard !layers.partial else { throw MemError.invalid("Scope exceeds complete day assembly; select smaller explicit action scopes") }
        if scope.kind == "activity" {
            guard let group=layers.activities.first(where:{$0.id == scope.id}) else { throw MemError.invalid("Activity changed or unavailable") }
            return (group.actionIDs,group.inputRevision)
        }
        let interval=try DayScope.interval(day:day,timezone:zone)
        let storedCount=Int(try rows("SELECT count(*) FROM records WHERE julianday(json_extract(body,'$.at'))>=julianday(?) AND julianday(json_extract(body,'$.at'))<julianday(?)",[iso(interval.start),iso(interval.end)]).first![0])!
        guard storedCount == layers.summary.actionCount else { throw MemError.invalid("Day contains unavailable or excluded records; exact owner scope needs review before whole-day deletion or correction") }
        return (layers.activities.flatMap(\.actionIDs),layers.summary.inputRevision)
    }
    /// kind "range": every stored record with `start <= at < end`, visible or hidden by the current policy (an excluded
    /// app's or a skipped site's rows in the range go too: the owner asked for the time, not for what is shown). The
    /// revision marks each one's id and revision.
    func rangeActions(_ scope:MemoryActionScope) throws -> (ids:[String],revision:String) {
        let bounds=try Self.rangeBounds(scope)
        let found=try rows("SELECT id,revision FROM records WHERE julianday(json_extract(body,'$.at'))>=julianday(?) AND julianday(json_extract(body,'$.at'))<julianday(?) ORDER BY id",
                           [Self.actionBound(bounds.start),Self.actionBound(bounds.end)])
        return (found.map { $0[0] },fingerprint(found.map { $0[0]+"|"+$0[1] }.joined(separator:"\n")))
    }
    static func rangeBounds(_ scope:MemoryActionScope) throws -> DateInterval {
        guard scope.kind == "range", let a=scope.start.flatMap(timestamp), let b=scope.end.flatMap(timestamp), a < b else { throw MemError.invalid("A range needs a start before its end") }
        guard b.timeIntervalSince(a) <= MemoryActionScope.rangeLimit else { throw MemError.invalid("Choose a shorter range") }
        guard scope.timezone.flatMap(TimeZone.init(identifier:)) != nil else { throw MemError.invalid("Exact IANA timezone required") }
        return DateInterval(start:a,end:b)
    }
    /// Moments (in the scope's time zone) holding at least one of `ids`, counted over the local days the range touches;
    /// nil past 31 days (the preview then counts actions only).
    func rangeMomentCount(_ scope:MemoryActionScope,ids:Set<String>,now:Date) throws -> Int? {
        let bounds=try Self.rangeBounds(scope), zone=scope.timezone!
        guard !ids.isEmpty else { return 0 }
        var day=try DayScope.key(bounds.start,timezone:zone), count=0
        for _ in 0..<32 {
            let interval=try DayScope.interval(day:day,timezone:zone)
            count += try dayLayers(day:day,timezone:zone,limit:1,now:now).activities.filter { $0.actionIDs.contains(where:ids.contains) }.count
            guard interval.end < bounds.end else { return count }
            day=try DayScope.key(interval.end,timezone:zone)
        }
        return nil
    }
    /// gold r3-store (gate item 5): the scope is read first, outside the write transaction, in the day read's short
    /// statements (a whole day's assembly after a Correct took 280-520 ms, all of it holding the store's lock and the
    /// file's write lock, so the recorder's saves and heartbeat waited). The transaction then only checks that nothing
    /// the preview depends on changed meanwhile (the disclosure revision, which every deletion, correction, choice or
    /// recording change moves, and the action read epoch) and records the preview. A change meanwhile reads the scope
    /// again; after `scopeTries` it is read inside the transaction, as before. The preview says exactly what the
    /// transaction saw, and Forget checks the scope again itself (`executeDeletion`).
    public func prepareDeletion(scope:MemoryActionScope,now:Date=Date()) throws -> DeletionPreview {
        // Forget a time range: a range's moments are counted before the write lock is taken (whole days are
        // assembled); the count only informs the question, the commit checks the exact actions again.
        let moments:Int?
        if scope.kind == "range" {
            let ids=try rangeActions(scope).ids
            // No saved actions, but frozen summaries of expired days span the range: those are what it forgets.
            let frozen=ids.isEmpty ? try frozenLevelCount(overlapping:Self.rangeBounds(scope)) : 0
            guard !ids.isEmpty || frozen > 0 else { throw MemError.invalid(DeletionPreview.nothingInRange) }
            moments=ids.isEmpty ? 0 : try rangeMomentCount(scope,ids:Set(ids),now:now)
        } else { moments=nil }
        // gold r3-store: the scope is read outside the write transaction; the transaction only checks nothing moved.
        tries: for _ in 0..<Self.scopeTries {
            let revision=try disclosureRevision(), epoch=try actionReadEpoch()
            let selected:(ids:[String],revision:String)
            do { selected=try scopeActions(scope,now:now) }
            catch MemError.invalid(let text) where text == Self.dayChanged { continue }
            // Any other refusal (a whole day whose count moved while it was read, say) is judged inside the
            // transaction, exactly as before.
            catch MemError.invalid { break tries }
            let preview=try transaction { () -> DeletionPreview? in
                guard try disclosureRevision() == revision, try actionReadEpoch() == epoch else { return nil }
                return try recordPreview(scope:scope,selected:selected,moments:moments,revision:revision,now:now)
            }
            if let preview { return preview }
        }
        return try transaction {
            let selected=try scopeActions(scope,now:now)
            return try recordPreview(scope:scope,selected:selected,moments:moments,revision:try disclosureRevision(),now:now)
        }
    }
    static let scopeTries=3
    static let dayChanged="Day changed; retry fresh read"
    private func recordPreview(scope:MemoryActionScope,selected:(ids:[String],revision:String),moments:Int?,revision:String,now:Date) throws -> DeletionPreview {
        let ids=selected.ids
        let limit=scope.kind == "range" ? MemoryActionScope.rangeActionLimit : 5000
        let summaries=scope.kind == "range" && ids.isEmpty ? try frozenLevelCount(overlapping:Self.rangeBounds(scope)) : 0
        if scope.kind == "range" && ids.isEmpty && summaries == 0 { throw MemError.invalid(DeletionPreview.nothingInRange) }
        guard !ids.isEmpty || summaries > 0, ids.count <= limit else { throw MemError.invalid(scope.kind == "range" ? "Choose a shorter range" : "Select 1 through 5000 exact actions") }
        try requireKnownSummaryDependencies(ids)
        let warning:String
        switch scope.kind {
        case "day": warning="Deletes ALL selected-day actions and owned evidence, not just summary text. External originals and exported copies are not recalled."
        case "range": warning=DeletionPreview.rangeEdges+" "+DeletionPreview.notRecalled
        default: warning=DeletionPreview.notRecalled
        }
        let preview=DeletionPreview(id:UUID().uuidString,scope:scope,actionIDs:ids.sorted(),actionCount:ids.count,revision:revision,expiresAt:iso(now.addingTimeInterval(300)),warning:warning,
                                    momentCount:moments,rangeStart:scope.kind == "range" ? scope.start : nil,rangeEnd:scope.kind == "range" ? scope.end : nil,
                                    scopeRevision:scope.kind == "range" ? selected.revision : nil,summaryCount:summaries > 0 ? summaries : nil)
        try exec("INSERT INTO deletion_previews VALUES(?,?,'pending',NULL)",[preview.id,json(preview)])
        return preview
    }
    func requireKnownSummaryDependencies(_ ids:[String]) throws {
        // Legacy summary-only imports lack action-reference provenance. Do not
        // pretend to cascade them, or erase an unrelated summary by guess.
        if try !rows("SELECT name FROM sqlite_master WHERE name='migration_originals'").isEmpty {
            let uncertain=try rows("SELECT m.id FROM migration_originals m JOIN records r ON EXISTS(SELECT 1 FROM json_each(?) selected WHERE selected.value=r.id) WHERE json_extract(m.body,'$.family')='activity-summary' AND julianday(json_extract(m.body,'$.at'))<=julianday(json_extract(r.body,'$.at')) AND julianday(coalesce(json_extract(m.body,'$.end'),json_extract(m.body,'$.at')))>=julianday(json_extract(r.body,'$.at')) LIMIT 1",[json(ids)])
            guard uncertain.isEmpty else { throw MemError.invalid("Overlapping imported summary has no action references. Review its exact derived-summary scope before deleting; nothing removed.") }
        }
    }
    public func cancelDeletion(_ previewID:String) throws {
        try exec("UPDATE deletion_previews SET state='cancelled' WHERE id=? AND state='pending'",[previewID])
    }
    public func deletionReceipt(previewID:String) throws -> DeletionReceipt? {
        guard let body=try rows("SELECT receipt FROM deletion_previews WHERE id=? AND state='committed'",[previewID]).first?.first else { return nil }
        var receipt=try decode(DeletionReceipt.self,body)
        let tracked=try rows("SELECT id FROM search_index_state WHERE id IN (SELECT value FROM json_each(?)) LIMIT 1",[json(receipt.actionIDs)])
        receipt.searchCleanup=tracked.isEmpty ? "no_tracked_index_entries" : "pending_source_reads_already_blocked"
        return receipt
    }
    public func executeDeletion(previewID:String,confirmed:Bool,now:Date=Date()) throws -> DeletionReceipt {
        guard confirmed else { throw MemError.denied }
        let receipt=try transaction { () -> DeletionReceipt in
            guard let row=try rows("SELECT body,state,coalesce(receipt,'') FROM deletion_previews WHERE id=?",[previewID]).first else { throw MemError.invalid("Deletion preview missing") }
            if row[1] == "committed" { return try decode(DeletionReceipt.self,row[2]) }
            let preview=try decode(DeletionPreview.self,row[0])
            // A range is judged by its own actions (read again below, each at its revision), not the store-wide disclosure
            // revision: a save anywhere else (a typing burst, a Chrome page) must not refuse it (r1 forget-range).
            guard row[1] == "pending", timestamp(preview.expiresAt).map({$0 >= now}) == true,
                  try preview.scope.kind == "range" && preview.scopeRevision != nil || preview.revision == disclosureRevision() else { throw MemError.invalid("Deletion scope changed, expired or cancelled; review a new preview") }
            // The scope is read again inside this transaction: the same actions (and, for a range, each at the same
            // revision) or nothing is deleted.
            let current=try scopeActions(preview.scope,now:now)
            guard preview.actionIDs == current.ids.sorted(), preview.scopeRevision.map({ $0 == current.revision }) ?? true else { throw MemError.invalid("Deletion scope changed, expired or cancelled; review a new preview") }
            if preview.scope.kind == "range" {
                try deleteActionsWithinTransaction(preview.actionIDs)
                // Written summaries a range can't be rewritten from: a frozen level note (its actions already expired)
                // that spans any of the range goes, with the notes above it.
                try dropFrozenLevels(overlapping:try Self.rangeBounds(preview.scope))
            } else {
                for id in preview.actionIDs { try deleteActionWithinTransaction(id) }
            }
            try exec("DELETE FROM receipts")
            try invalidateDisclosure()
            let receipt=DeletionReceipt(previewID:preview.id,actionIDs:preview.actionIDs,deletedAt:iso(now),deletionRevision:try deletionRevision(),attachmentCleanup:"pending",searchCleanup:"pending_source_reads_already_blocked")
            try exec("UPDATE deletion_previews SET state='committed',receipt=? WHERE id=?",[json(receipt),preview.id])
            return receipt
        }
        scheduleSearchRefresh()
        // gold/int r3 review: the deletion is committed; a cleanup bookkeeping write that fails (another connection held
        // the history) must not report it as not deleted. Its receipt then says the cleanup is pending.
        do { return try finishDeletionCleanup(receipt) }
        catch { var pending=receipt; pending.attachmentCleanup="pending_retry_required"; return pending }
    }
    private func finishDeletionCleanup(_ receipt:DeletionReceipt) throws -> DeletionReceipt {
        var receipt=receipt
        do { try cleanupMigrationAttachments(); receipt.attachmentCleanup="complete" }
        catch { receipt.attachmentCleanup="pending_retry_required" }
        // Logical deletion remains committed even if filesystem cleanup fails.
        try exec("UPDATE deletion_previews SET receipt=? WHERE id=? AND state='committed'",[json(receipt),receipt.previewID])
        return receipt
    }
    func deleteActionWithinTransaction(_ id:String) throws {
        try exec("INSERT OR IGNORE INTO tombstones VALUES(?)",[id])
        try exec("DELETE FROM summaries WHERE id=?",[id]); try exec("DELETE FROM records WHERE id=?",[id])
        try purgeMigrationOriginal(id)
        // Sealed words and their stub go with the record.
        try deleteTypedWithinTransaction(id)
        try purgeActionDerivatives(id)
    }
    /// `deleteActionWithinTransaction` for many actions at once (a range), in the same steps, 500 ids a statement:
    /// tombstone, per-action summary, record, imported original, sealed words and stub, then everything derived from
    /// them (`purgeActionDerivatives(ids:)`: level notes, corrections, moment notes, writer requests, grouping edits).
    func deleteActionsWithinTransaction(_ ids:[String]) throws {
        let hasOriginals = !(try rows("SELECT name FROM sqlite_master WHERE type='table' AND name='migration_originals'")).isEmpty
        let typed=try hasTypedTables()
        for start in stride(from:0,to:ids.count,by:500) {
            let chunk=Array(ids[start..<min(ids.count,start+500)]), list=try json(chunk)
            try exec("INSERT OR IGNORE INTO tombstones SELECT value FROM json_each(?)",[list])
            try exec("DELETE FROM summaries WHERE id IN (SELECT value FROM json_each(?))",[list])
            try exec("DELETE FROM records WHERE id IN (SELECT value FROM json_each(?))",[list])
            if hasOriginals { try exec("DELETE FROM migration_originals WHERE id IN (SELECT value FROM json_each(?))",[list]) }
            if typed {
                try exec("DELETE FROM typed_text WHERE id IN (SELECT value FROM json_each(?))",[list])
                try exec("DELETE FROM typed_after WHERE id IN (SELECT value FROM json_each(?))",[list])
                try dropTypedRecipients(chunk)
            }
            try purgeActionDerivatives(ids:chunk)
        }
    }
    public func correctionHistory(kind:String,targetID:String,afterVersion:Int=0,limit:Int=50,now:Date=Date()) throws -> [UserCorrection] {
        guard try hasMemoryControls(), ["action","activity","day"].contains(kind) else { return [] }
        let epoch=try actionReadEpoch()
        let values=try rows("SELECT body FROM user_corrections WHERE kind=? AND target=? AND version>? ORDER BY version LIMIT ?",[kind,targetID,String(afterVersion),String(max(1,min(100,limit)))])
        let result=try values.compactMap { row -> UserCorrection? in
            let value=try decode(UserCorrection.self,row[0])
            for id in value.actionIDs { guard try permittedOriginal(id,now:now) != nil else { return nil } }
            return value
        }
        guard try epoch == actionReadEpoch() else { throw MemError.invalid("Correction scope changed") }
        return result
    }
    func latestCorrection(kind:String,targetID:String) throws -> UserCorrection? {
        guard try hasMemoryControls(), let body=try rows("SELECT body FROM user_corrections WHERE kind=? AND target=? ORDER BY version DESC LIMIT 1",[kind,targetID]).first?.first else { return nil }
        let correction=try decode(UserCorrection.self,body)
        return correction.text == nil ? nil : correction
    }
    func correctionList(actionIDs:[String],now:Date) throws -> [UserCorrection] {
        guard !actionIDs.isEmpty, try hasMemoryControls() else { return [] }
        let values=try rows("SELECT c.body FROM user_corrections c WHERE c.kind<>'action' AND c.version=(SELECT max(n.version) FROM user_corrections n WHERE n.kind=c.kind AND n.target=c.target) AND EXISTS(SELECT 1 FROM json_each(c.body,'$.actionIDs') refs JOIN json_each(?) requested ON refs.value=requested.value) ORDER BY c.kind,c.target",[json(actionIDs)])
        return try values.compactMap { row in
            let value=try decode(UserCorrection.self,row[0])
            guard value.text != nil else { return nil }
            for id in value.actionIDs { guard try permittedOriginal(id,now:now) != nil else { return nil } }
            return value
        }
    }
    private func saveCorrection(scope:MemoryActionScope,text:String?,expectedRevision:String,now:Date) throws -> UserCorrection {
        guard text == nil || (!text!.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty && text!.utf8.count <= 4000 && !Privacy.secret(text!)) else { throw MemError.invalid("Correction is empty, sensitive or too long") }
        return try transaction {
            let selected=try scopeActions(scope,now:now)
            guard selected.revision == expectedRevision, !selected.ids.isEmpty else { throw MemError.invalid("Correction target changed; refresh before saving") }
            let target=scope.kind == "day" ? "day_"+fingerprint(scope.day!+"|"+scope.timezone!) : scope.id!
            let version=(try rows("SELECT max(version) FROM user_corrections WHERE kind=? AND target=?",[scope.kind,target]).first?.first.flatMap(Int.init) ?? 0)+1
            let value=UserCorrection(targetKind:scope.kind,targetID:target,version:version,text:text,actionIDs:selected.ids.sorted(),authoredAt:iso(now))
            // The actions the previous version covered too: a regrouped moment or day may have had others.
            let prior=try rows("SELECT body FROM user_corrections WHERE kind=? AND target=? AND version=?",[scope.kind,target,String(version-1)]).first?.first.map { try decode(UserCorrection.self,$0).actionIDs } ?? []
            try exec("INSERT INTO user_corrections VALUES(?,?,?,?)",[scope.kind,target,String(version),json(value)])
            // gold/notes G20: only notes that cite what this edit changes (and their writer requests) go. Every other
            // note, on this day and every other, stays.
            try invalidateNotes(citing:value.actionIDs+prior)
            try invalidateDisclosure()
            return value
        }
    }
    public func correctAction(id:String,text:String?,expectedRevision:String,now:Date=Date()) throws -> UserCorrection {
        defer { scheduleSearchRefresh() }
        return try saveCorrection(scope:MemoryActionScope(kind:"action",id:id),text:text,expectedRevision:expectedRevision,now:now)
    }
    public func correctNote(scope:MemoryActionScope,text:String?,expectedRevision:String,now:Date=Date()) throws -> UserCorrection {
        guard ["activity","day"].contains(scope.kind) else { throw MemError.invalid("Explicit note scope required") }
        return try saveCorrection(scope:scope,text:text,expectedRevision:expectedRevision,now:now)
    }
    func applyCorrection(_ item:MemoryItem) throws -> MemoryItem {
        var item=item
        if let value=try latestCorrection(kind:"action",targetID:item.id), let text=value.text {
            item.correction=value; item.summary="User correction (not observed): "+text; item.inference=true
            item.actionState="user_corrected"
        }
        return item
    }
}
