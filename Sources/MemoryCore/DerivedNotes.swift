import Foundation

public struct NoteBullet: Codable, Equatable {
    public var text:String
    public var actionIDs:[String]
    /// observed, draft, sent, reported or interpretation. Interpretation is not fact.
    public var assertion:String
    public init(text:String,actionIDs:[String],assertion:String="observed") { self.text=text; self.actionIDs=actionIDs; self.assertion=assertion }
}
public struct NoteWriterRequest: Codable {
    public var id:String
    public var schemaVersion:Int
    public var targetKind:String
    public var targetID:String
    public var day:String
    public var timezone:String
    public var inputRevision:String
    public var policyRevision:String
    public var expiresAt:String
    public var actions:[CanonicalAction]
    public var actionCount:Int
    public var next:Int?
    public var corrections:[UserCorrection]? = nil
}
/// Who writes a note. fix/day-card (owner decision, 9/28): a cloud writer reads browser moments too, as their host and
/// their page titles cleaned (`TitleClean`: no address, unread count or app suffix; `cloudView`), with the words typed
/// there; local summaries, search and connected AI apps read them as recorded. Neither audience writes a moment made
/// only of idle rows.
public enum NoteAudience: String, Codable, Sendable {
    case local, cloud
    /// Every recorded action may go to a cloud writer, browser pages as `cloudView` shows them.
    public static func cloudEligible(_ a:CanonicalAction) -> Bool { true }
    /// A browser action as a cloud writer reads it: its host (actions carry the host only) and its page title cleaned
    /// (`TitleClean`), in a description rebuilt from those two (never the page's address or search terms). Typed rows
    /// keep their description (a word-count bucket, never words) with the cleaned title. Anything else is unchanged.
    public static func cloudView(_ a:CanonicalAction) -> CanonicalAction {
        guard !cloudEligible(bundle:a.bundle) else { return a }
        var v=a
        let title=TitleClean.clean(a.title,app:a.app,site:a.site)
        v.title=title; v.subject=title
        v.observedDescription=nil
        if a.kind != "keyboard.text_input" {
            let place=a.site.isEmpty ? "" : " on \(a.site)"
            v.description=title.isEmpty ? "Observed a page\(place) in \(a.app); reading is not established."
                : "Observed \(title)\(place) in \(a.app); reading is not established."
        }
        return v
    }
    /// A moment made only of idle rows (no app, no site): nothing to write.
    public static func idleOnly(_ activity:ActivityNote) -> Bool {
        activity.apps.allSatisfy(\.isEmpty) && activity.sites.allSatisfy(\.isEmpty) && (activity.bundles ?? []).allSatisfy(\.isEmpty)
    }
    /// A website typing row (chrome-typing-join-v1, `WebTypedRow`): typed words in Chrome (only the join types there).
    /// Its place is the page's title where page history saves one (fix/typing-e2e L5) or the host.
    public static func webTyped(_ a:CanonicalAction) -> Bool {
        a.kind == "keyboard.text_input" && a.bundle == "com.google.Chrome" && !a.site.isEmpty
    }
    /// What the cloud may see of an action's place: the page title cleaned (`cloudView`), never an address, an unread
    /// count or an app suffix (fix/sx-all: fix/typing-e2e's site-only rule under fix/day-card's owner decision).
    public static func cloudTitle(_ a:CanonicalAction) -> String { cloudView(a).title }
    /// Return and shortcut marker rows (N18): they only mark "in use", so they don't count toward the cloud's
    /// 100-action limit (they are still sent with the moment).
    public static func cloudMarker(kind:String) -> Bool { kind == "keyboard.submit" || kind == "keyboard.shortcut" }
    public static func cloudEligible(bundle:String) -> Bool { !CaptureSession.excludedBrowsers.contains(bundle) }
    /// Whether this audience may write a note for the activity: never one made only of idle rows (either audience).
    public func admits(_ activity:ActivityNote) -> Bool { !Self.idleOnly(activity) }
}
private struct StoredNoteRequest:Codable {
    var request:NoteWriterRequest; var actionIDs:[String]; var readThrough:Int
    var audience:NoteAudience = .local
    /// Private preparation authority, never accepted from a provider or old request.
    var allowGrowingSnapshot:Bool = false
    init(request:NoteWriterRequest,actionIDs:[String],readThrough:Int,audience:NoteAudience,allowGrowingSnapshot:Bool=false) {
        self.request=request; self.actionIDs=actionIDs; self.readThrough=readThrough; self.audience=audience
        self.allowGrowingSnapshot=allowGrowingSnapshot
    }
    private enum CodingKeys:String,CodingKey { case request,actionIDs,readThrough,audience,allowGrowingSnapshot }
    init(from decoder:Decoder) throws {
        let c=try decoder.container(keyedBy:CodingKeys.self)
        request=try c.decode(NoteWriterRequest.self,forKey:.request); actionIDs=try c.decode([String].self,forKey:.actionIDs)
        readThrough=try c.decode(Int.self,forKey:.readThrough)
        audience=try c.decodeIfPresent(NoteAudience.self,forKey:.audience) ?? .local
        allowGrowingSnapshot=try c.decodeIfPresent(Bool.self,forKey:.allowGrowingSnapshot) ?? false
    }
}
public struct NoteActionPage:Codable { public var actions:[CanonicalAction]; public var next:Int?; public var actionCount:Int }
public struct NoteWriterOutput: Codable, Equatable {
    public var requestID:String
    public var title:String
    public var bullets:[NoteBullet]
    public var generator:String
    public var generatorVersion:String
    public init(requestID:String,title:String,bullets:[NoteBullet],generator:String,generatorVersion:String) {
        self.requestID=requestID; self.title=title; self.bullets=bullets; self.generator=generator; self.generatorVersion=generatorVersion
    }
}
public struct GeneratedNote: Codable {
    public var id:String
    public var version:Int
    public var schemaVersion:Int
    public var generatedAt:String
    public var inputRevision:String
    public var actionIDs:[String]
    public var output:NoteWriterOutput
    public var status:String
}
public struct NoteTarget: Codable {
    public var kind:String
    public var id:String
    public var day:String
    public var timezone:String
    public var actionCount:Int
    public var status:String
    public var inputRevision:String
}
extension MemoryStore {
    /// Source-derived pending work, not a second action queue or provider runner.
    /// Under `.cloud`, activities (and the day) with no cloud-eligible action are not targets.
    public func noteTargets(day:String,timezone:String,audience:NoteAudience = .local,now:Date=Date()) throws -> [NoteTarget] {
        let layers=try dayLayers(day:day,timezone:timezone,now:now)
        var targets=layers.activities.filter { $0.status != "ready" && audience.admits($0) }.map {
            NoteTarget(kind:"activity",id:$0.id,day:day,timezone:timezone,actionCount:$0.actionIDs.count,status:layers.partial ? "incomplete" : "pending",inputRevision:$0.inputRevision)
        }
        if layers.summary.status != "ready", layers.summary.actionCount > 0, layers.activities.contains(where:audience.admits) {
            targets.append(NoteTarget(kind:"day",id:"day_"+fingerprint(day+"|"+timezone),day:day,timezone:timezone,actionCount:layers.summary.actionCount,status:layers.partial ? "incomplete" : "pending",inputRevision:layers.summary.inputRevision))
        }
        return targets
    }
    func storedNote(id:String,inputRevision:String) throws -> GeneratedNote? {
        guard try hasActionLayers() else { return nil }
        return try storedNote(id:id,inputRevision:inputRevision,checked:true)
    }
    /// For a caller that already checked the note tables exist (the day assembly asks once, not per moment).
    func storedNote(id:String,inputRevision:String,checked:Bool) throws -> GeneratedNote? {
        guard let body=try rows("SELECT body FROM generated_notes WHERE id=? AND input_revision=? ORDER BY version DESC LIMIT 1",[id,inputRevision]).first?.first else { return nil }
        return try decode(GeneratedNote.self,body)
    }
    /// fix/day-card (stale-while-updating): the newest note stored for `id`, whatever input revision it was written
    /// for. Display only. A Forget (range, moment, action, what I typed) deletes every note citing a forgotten action,
    /// so this never returns a forgotten note.
    public func latestNote(id:String) throws -> GeneratedNote? {
        guard try hasActionLayers(), let body=try rows("SELECT body FROM generated_notes WHERE id=? ORDER BY version DESC LIMIT 1",[id]).first?.first else { return nil }
        return try? decode(GeneratedNote.self,body)
    }
    /// The same note, only when every action it cites is still among `actions` (the moment's visible members): a note
    /// about actions a policy now hides, or that moved to another moment, is never shown for this one.
    func latestNote(id:String,within actions:Set<String>) throws -> GeneratedNote? {
        guard let note=try rows("SELECT body FROM generated_notes WHERE id=? ORDER BY version DESC LIMIT 1",[id]).first?.first.flatMap({ try? decode(GeneratedNote.self,$0) }),
              !note.actionIDs.isEmpty, note.actionIDs.allSatisfy(actions.contains) else { return nil }
        return note
    }
    /// Providers own execution. Core owns snapshot selection and publication.
    /// Under `.cloud`, browser actions are left out of the request before its size check.
    public func prepareNote(kind:String,day:String,timezone:String,activityID:String?=nil,audience:NoteAudience = .local,now:Date=Date(),allowGrowingSnapshot:Bool=false) throws -> NoteWriterRequest {
      do {
        // gold/notes G26: a capture landing while the request is read changes the disclosure revision. Nothing has
        // left the Mac yet, so read again (the day is cached, so this is cheap) instead of failing the note. The last
        // try builds the request inside the write transaction from the warm day, so nothing can land in between; if
        // the day went cold meanwhile it still fails as raced (the writer tries again later), never a whole-day read
        // while capture waits.
        for _ in 0..<2 {
            do { return try prepareNoteOnce(kind:kind,day:day,timezone:timezone,activityID:activityID,audience:audience,now:now,fenced:false,allowGrowingSnapshot:allowGrowingSnapshot) }
            catch MemError.invalid(let message) where message == Self.preparationRaced {discardTypedNarrativeCarry()}
        }
        _ = try? assembleDay(day:day,timezone:timezone,limit:200,now:now,notes:false)
        do { return try pendingNotePreparationTransaction(now:now) { try prepareNoteOnce(kind:kind,day:day,timezone:timezone,activityID:activityID,audience:audience,now:now,fenced:true,allowGrowingSnapshot:allowGrowingSnapshot) } }
        catch is DayAssemblyCold { throw MemError.invalid(Self.preparationRaced) }
      } catch {discardTypedNarrativeCarry();throw error}
    }
    static let preparationRaced="Writer source changed before preparation"
    /// `fenced`: the caller holds the write transaction, so the day must already be warm.
    private func prepareNoteOnce(kind:String,day:String,timezone:String,activityID:String?,audience:NoteAudience,now:Date,fenced:Bool,allowGrowingSnapshot:Bool) throws -> NoteWriterRequest {
        let revision=try disclosureRevision(), policy=try policy().revision
        let assembled=try assembleDay(day:day,timezone:timezone,limit:200,now:now,notes:false,warmOnly:fenced)
        let layers=assembled.day
        guard !layers.partial, ["activity","day"].contains(kind) else { throw MemError.invalid("Incomplete or invalid note scope") }
        let group=layers.activities.first { $0.id == activityID }
        guard kind == "day" || group != nil else { throw MemError.invalid("Activity no longer exists") }
        var ids=kind == "day" ? layers.activities.flatMap(\.actionIDs) : group!.actionIDs
        if audience == .cloud {
            ids=try ids.filter { try cloudEligible($0,known:assembled.actions) }
            guard !ids.isEmpty else { throw MemError.invalid("No actions this writer may read") }
        }
        guard !ids.isEmpty, ids.count <= 5000 else { throw MemError.invalid("Writer scope needs 1 through 5000 actions") }
        let permitted=try ids.prefix(100).compactMap { try assembled.actions[$0] ?? action($0,now:now) }
            .map { audience == .cloud ? NoteAudience.cloudView($0) : $0 }
        guard permitted.count == min(100,ids.count) else { throw MemError.invalid("Writer evidence changed") }
        let target=kind == "day" ? "day_"+fingerprint(day+"|"+timezone) : group!.id
        let input=kind == "day" ? layers.summary.inputRevision : group!.inputRevision
        let growing = allowGrowingSnapshot && audience == .local && kind == "activity"
        let request=NoteWriterRequest(id:UUID().uuidString,schemaVersion:1,targetKind:kind,targetID:target,day:day,timezone:timezone,inputRevision:input,policyRevision:policy,expiresAt:iso(now.addingTimeInterval(300)),actions:permitted,actionCount:ids.count,next:ids.count > 100 ? 100 : nil,corrections:try corrections(actionIDs:ids,audience:audience,now:now))
        guard try json(request).utf8.count <= 256_000 else { throw MemError.invalid("Writer input exceeds private bounded contract") }
        func save() throws -> NoteWriterRequest {
            guard try revision == disclosureRevision() else { throw MemError.invalid(Self.preparationRaced) }
            for row in try rows("SELECT body FROM note_requests WHERE state='pending' AND json_extract(body,'$.request.targetID')=?",[target]) {
                let stored=try decode(StoredNoteRequest.self,row[0]), prior=stored.request
                // A pending local request is never handed to a cloud writer, or the reverse.
                if stored.audience == audience, stored.allowGrowingSnapshot == growing, prior.inputRevision == input, prior.policyRevision == policy, timestamp(prior.expiresAt).map({$0 >= now}) == true { return prior }
            }
            try exec("UPDATE note_requests SET state='superseded',body='' WHERE state='pending' AND json_extract(body,'$.request.targetID')=?",[target])
            try exec("INSERT INTO note_requests VALUES(?,?,'pending')",[request.id,json(StoredNoteRequest(request:request,actionIDs:ids,readThrough:permitted.count,audience:audience,allowGrowingSnapshot:growing))])
            return request
        }
        return fenced ? try save() : try pendingNotePreparationTransaction(now:now) { try save() }
    }
    /// gold/notes G18: the day a request covers is read before the write transaction opens, so inside it only what
    /// changed since (usually nothing) is read, and the store is never held for a whole day's assembly while capture
    /// waits. If the day changed in between, warm it again (twice); only then read it inside.
    private func withWarmDay<T>(request id:String,now:Date,_ body:(_ warmOnly:Bool) throws -> T) throws -> T {
        for attempt in 0..<3 {
            if let raw=try rows("SELECT body FROM note_requests WHERE id=?",[id]).first?.first, let stored=try? decode(StoredNoteRequest.self,raw) {
                _ = try? assembleDay(day:stored.request.day,timezone:stored.request.timezone,now:now,notes:false)
            }
            do { return try transaction { try body(attempt < 2) } }
            catch is DayAssemblyCold { continue }
        }
        return try transaction { try body(false) }
    }
    public func noteActions(requestID:String,after:Int,now:Date=Date()) throws -> NoteActionPage {
      try withWarmDay(request:requestID,now:now) { warmOnly in
        let revision=try disclosureRevision()
        guard let row=try rows("SELECT body,state FROM note_requests WHERE id=?",[requestID]).first, row[1] == "pending" else { throw MemError.invalid("Writer request not pending") }
        var stored=try decode(StoredNoteRequest.self,row[0])
        let assembled=try validateNoteRequest(stored,now:now,checkExpiry:true,warmOnly:warmOnly)
        guard after >= 0, after <= stored.readThrough, after < stored.actionIDs.count else { throw MemError.invalid("Invalid or skipped writer page offset") }
        let end=min(after+100,stored.actionIDs.count)
        let actions=try stored.actionIDs[after..<end].compactMap { try assembled.actions[$0] ?? action($0,now:now) }
            .map { stored.audience == .cloud ? NoteAudience.cloudView($0) : $0 }
        guard actions.count == end-after, try revision == disclosureRevision(), try rows("SELECT state FROM note_requests WHERE id=?",[requestID]).first?.first == "pending" else { throw MemError.invalid("Writer page changed or cancelled") }
        stored.readThrough=max(stored.readThrough,end)
        try exec("UPDATE note_requests SET body=? WHERE id=?",[json(stored),requestID])
        return NoteActionPage(actions:actions,next:end < stored.actionIDs.count ? end : nil,actionCount:stored.actionIDs.count)
      }
    }
    public func cancelNote(_ id:String) throws {
        try exec("UPDATE note_requests SET state='cancelled',body='' WHERE id=? AND state='pending'",[id])
    }
    /// Provider dispatch/revalidation. A boolean cached by a provider is never authority.
    /// A read only: it writes nothing, so it takes no write transaction (gold/notes G18). Commit checks again.
    public func validatePreparedNote(_ id:String, revisions:[String:String], now:Date=Date()) throws {
        guard let row=try rows("SELECT body,state FROM note_requests WHERE id=?",[id]).first,
              row[1] == "pending" else { throw MemError.invalid("Writer request no longer pending") }
        let stored=try decode(StoredNoteRequest.self,row[0])
        let assembled=try validateNoteRequest(stored,now:now,checkExpiry:true)
        guard revisions.count<=5000, stored.readThrough == stored.actionIDs.count,
              Set(revisions.keys) == Set(stored.actionIDs) else { throw MemError.invalid("Incomplete writer input") }
        for (id,revision) in revisions {
            guard try (assembled.actions[id] ?? action(id,now:now))?.revision == revision else { throw MemError.invalid("Writer source changed") }
        }
        guard try rows("SELECT state FROM note_requests WHERE id=?",[id]).first?.first == "pending" else { throw MemError.invalid("Writer request no longer pending") }
    }
    /// A failed provider may retry exactly the same request while it is pending.
    public func commitNote(_ output:NoteWriterOutput,now:Date=Date()) throws -> GeneratedNote {
        try withWarmDay(request:output.requestID,now:now) { warmOnly in
            guard let row=try rows("SELECT body,state FROM note_requests WHERE id=?",[output.requestID]).first else { throw MemError.invalid("Unknown writer request") }
            if row[1] == "committed" {
                guard let raw=try rows("SELECT body FROM generated_notes WHERE json_extract(body,'$.output.requestID')=?",[output.requestID]).first?.first else { throw MemError.invalid("Committed note invalidated") }
                let note=try decode(GeneratedNote.self,raw)
                guard note.output == output else { throw MemError.invalid("Conflicting retry for committed request") }
                // Retry acknowledgement cannot disclose a now-stale derived note.
                let stored=try decode(StoredNoteRequest.self,row[0])
                try validateNoteRequest(stored,now:now,checkExpiry:false,warmOnly:warmOnly)
                return note
            }
            guard row[1] == "pending" else { throw MemError.invalid("Writer request cancelled or invalidated") }
            let stored=try decode(StoredNoteRequest.self,row[0]), request=stored.request
            let assembled=try validateNoteRequest(stored,now:now,checkExpiry:true,warmOnly:warmOnly)
            guard stored.readThrough == stored.actionIDs.count else { throw MemError.invalid("Read all writer input pages before publishing coverage") }
            guard !output.title.isEmpty, output.title.count <= 160, !Privacy.secret(output.title), !output.bullets.isEmpty, output.bullets.count <= 20,
                  !output.generator.isEmpty, output.generator.count <= 100, !output.generatorVersion.isEmpty, output.generatorVersion.count <= 100,
                  output.generator.range(of:"^[A-Za-z0-9._/-]{1,100}$",options:.regularExpression) != nil,
                  output.generatorVersion.range(of:"^[A-Za-z0-9._/-]{1,100}$",options:.regularExpression) != nil,
                  try json(output).utf8.count <= 16000 else { throw MemError.invalid("Invalid bounded writer output") }
            // fix/summary-fallback: code's fallback note is stored as code's, and nothing else is stored as it.
            guard CodeFallbackNote.hasValidProviderPair(output) else { throw MemError.invalid("Invalid bounded writer output") }
            let referenced=Set(output.bullets.flatMap(\.actionIDs))
            guard referenced.isSubset(of:Set(stored.actionIDs)) else { throw MemError.invalid("Unreferenced note action") }
            if stored.audience == .cloud {
                guard try (stored.actionIDs+referenced).allSatisfy({ try cloudEligible($0,known:assembled.actions) }) else { throw MemError.invalid("Cloud note references browser activity") }
                // A correction's text may repeat a local note written from browser pages (a page's full title, a
                // search): it never goes to a cloud writer.
                // It stays local when it covers any browser action (the strict rule `corrections` prepared it with).
                guard try (request.corrections ?? []).flatMap(\.actionIDs).allSatisfy({ id in
                    if let a=assembled.actions[id] { return NoteAudience.cloudEligible(bundle:a.bundle) }
                    return try cloudEligible(id)
                }) else { throw MemError.invalid("Cloud note references browser activity") }
            }
            let permitted=Dictionary(uniqueKeysWithValues:try referenced.compactMap { id -> (String,CanonicalAction)? in
                guard let value=try assembled.actions[id] ?? action(id,now:now) else { return nil }; return (id,value)
            })
            for bullet in output.bullets {
                guard !bullet.text.isEmpty, bullet.text.count <= 800, !Privacy.secret(bullet.text), !bullet.actionIDs.isEmpty,
                      Set(bullet.actionIDs).count == bullet.actionIDs.count,
                      Set(bullet.actionIDs).isSubset(of:Set(permitted.keys)),
                      ["observed","draft","submitted","sent","reported","interpretation"].contains(bullet.assertion) else { throw MemError.invalid("Unreferenced or invalid note claim") }
                // summaries/v3 (validator9): "sent", "delivered" and "published" still need a delivery receipt. The send leads
                // (emailed, messaged, posted, texted, replied) need a detected send gesture on every typed row the bullet
                // cites (label "submitted"), or a receipt for every action it cites.
                let claimsSend=(output.title+" "+bullet.text).range(of:"(?i)\\b(sent|delivered|published)\\b",options:.regularExpression) != nil
                let allSent=bullet.actionIDs.allSatisfy({permitted[$0]?.state == "sent"})
                if bullet.assertion == "sent" || claimsSend {
                    guard bullet.assertion == "sent", allSent else { throw MemError.invalid("Send claim lacks verified delivery evidence") }
                }
                let claimsSubmit=(output.title+" "+bullet.text).range(of:"(?i)\\b(emailed|messaged|posted|texted|replied)\\b",options:.regularExpression) != nil
                let typed=bullet.actionIDs.compactMap({permitted[$0]}).filter({$0.kind == "keyboard.text_input"})
                if bullet.assertion == "submitted" || (claimsSubmit && !(bullet.assertion == "sent" && allSent)) {
                    // notes-quality: an email's To and Subject fields are sealed as their own rows; the body's detected send
                    // covers them (they were sent with it), so only the other rows need their own.
                    let own=try typed.filter { try !["to","subject"].contains(typedField(for:$0.id)) }
                    guard bullet.assertion == "submitted", !own.isEmpty, own.allSatisfy({$0.state == "submitted"}) else { throw MemError.invalid("Send claim lacks a detected send") }
                }
                if bullet.assertion == "draft" && !bullet.actionIDs.allSatisfy({["draft","typed","drafted_request","submitted"].contains(permitted[$0]?.state ?? "")}) { throw MemError.invalid("Draft claim has mismatched evidence") }
                let correctedNoteIDs=Set((request.corrections ?? []).flatMap(\.actionIDs))
                if bullet.assertion == "observed", bullet.actionIDs.contains(where:{permitted[$0]?.correction != nil || correctedNoteIDs.contains($0)}) { throw MemError.invalid("Corrected text is user-authored, not observed; label interpretation or reported") }
                guard (output.title+" "+bullet.text).range(of:"(?i)\\b(spent|read for|worked for)\\s+\\d+|\\bwas reading\\b",options:.regularExpression) == nil else { throw MemError.invalid("Observation duration does not prove attention") }
            }
            // Safe typing D: a note may copy at most 5 words in a row from typed words.
            try typedVerbatimGuard(texts:[output.title]+output.bullets.map(\.text),actionIDs:stored.actionIDs)
            let version=(try rows("SELECT max(version) FROM generated_notes WHERE id=?",[request.targetID]).first?.first.flatMap(Int.init) ?? 0)+1
            let note=GeneratedNote(id:request.targetID,version:version,schemaVersion:1,generatedAt:iso(now),inputRevision:request.inputRevision,actionIDs:stored.actionIDs,output:output,status:"generated_unverified")
            try exec("INSERT INTO generated_notes VALUES(?,?,?,?)",[note.id,String(note.version),note.inputRevision,json(note)])
            // Keep only what a retry needs to check: the writer input is not kept once its note is committed (it was
            // already dropped for typed rows; gold/notes G63 drops it for every note, and a retry's inputRevision
            // check still covers every action).
            var kept=stored; kept.request.actions=[]
            try exec("UPDATE note_requests SET state='committed',body=? WHERE id=?",[json(kept),request.id])
            try pruneNoteHistory(committed:note,requestID:request.id)
            return note
        }
    }
    /// Corrections for a request. Under `.cloud`, a correction that covers any
    /// browser action (or any action that is gone) is left out whole: its text
    /// is often pre-filled from a local note that was written from Chrome pages.
    func corrections(actionIDs:[String],audience:NoteAudience,now:Date) throws -> [UserCorrection] {
        let all=try correctionList(actionIDs:actionIDs,now:now)
        guard audience == .cloud else { return all }
        return try all.filter { try $0.actionIDs.allSatisfy(cloudEligible) }
    }
    /// Whether the stored record is outside every browser (the rule for corrections). A missing record is not.
    private func cloudEligible(_ id:String) throws -> Bool {
        guard let bundle=try rows("SELECT json_extract(body,'$.bundle') FROM records WHERE id=?",[id]).first?.first else { return false }
        return NoteAudience.cloudEligible(bundle:bundle)
    }
    /// Whether a cloud writer may read the action: every recorded action may (fix/day-card), browser pages as
    /// `NoteAudience.cloudView` shows them. A missing record is not eligible.
    private func cloudEligible(_ id:String,known:[String:CanonicalAction]) throws -> Bool {
        if let action=known[id] { return NoteAudience.cloudEligible(action) }
        return try !rows("SELECT 1 FROM records WHERE id=?",[id]).isEmpty
    }
    /// Shared with ActivityLayers: a snapshot is still about the exact original actions,
    /// subject, note privacy binding and corrections, even when a new tail was appended.
    static func activityInputRevision(_ members:[CanonicalAction],binding:String,name:String,corrections:[UserCorrection]) throws -> String {
        fingerprint(try json(members)+binding+name+json(corrections))
    }
    @discardableResult private func validateNoteRequest(_ stored:StoredNoteRequest,now:Date,checkExpiry:Bool,warmOnly:Bool=false) throws -> AssembledDay {
        let request=stored.request
        guard request.schemaVersion == 1, try policy().revision == request.policyRevision,
              !checkExpiry || timestamp(request.expiresAt).map({$0 >= now}) == true else { throw MemError.invalid("Writer request expired or policy changed") }
        let assembled=try assembleDay(day:request.day,timezone:request.timezone,now:now,notes:false,warmOnly:warmOnly)
        let layers=assembled.day
        let input=request.targetKind == "day" ? layers.summary.inputRevision : layers.activities.first(where:{$0.id == request.targetID})?.inputRevision
        guard !layers.partial else { throw MemError.invalid("Late or changed actions invalidated note; prepare again") }
        if input != request.inputRevision {
            guard stored.allowGrowingSnapshot, stored.audience == .local, request.targetKind == "activity",
                  let group=layers.activities.first(where:{$0.id == request.targetID}),
                  !stored.actionIDs.isEmpty, group.actionIDs.count > stored.actionIDs.count,
                  Array(group.actionIDs.prefix(stored.actionIDs.count)) == stored.actionIDs else {
                throw MemError.invalid("Late or changed actions invalidated note; prepare again")
            }
            let original=try stored.actionIDs.map { id -> CanonicalAction in
                guard let action=try assembled.actions[id] ?? self.action(id,now:now) else { throw MemError.invalid("Writer action changed or was removed") }
                return action
            }
            guard try Self.activityInputRevision(original,binding:policy().notesBinding,name:group.subject,corrections:group.corrections ?? []) == request.inputRevision else {
                throw MemError.invalid("Writer snapshot changed; prepare again")
            }
        }
        for action in request.actions { guard try (assembled.actions[action.id] ?? self.action(action.id,now:now))?.revision == action.revision else { throw MemError.invalid("Writer action changed or was removed") } }
        return assembled
    }
    /// gold/notes G63: note tables stay bounded. After a commit, requests nothing reads any more go (superseded,
    /// cancelled, invalidated, and this target's older committed requests), and so do older versions of this note
    /// that covered only part of what the new one covers (a moment or day that grew). Versions for other inputs
    /// stay, so undoing an edit can still find its note.
    private func pruneNoteHistory(committed note:GeneratedNote,requestID:String) throws {
        try exec("DELETE FROM note_requests WHERE id<>? AND (state IN ('superseded','cancelled','invalidated') OR (state='committed' AND json_valid(body) AND json_extract(body,'$.request.targetID')=?))",[requestID,note.id])
        try exec("DELETE FROM generated_notes WHERE id=? AND version<? AND NOT EXISTS(SELECT 1 FROM json_each(generated_notes.body,'$.actionIDs') r WHERE r.value NOT IN (SELECT value FROM json_each(?)))",[note.id,String(note.version),json(note.actionIDs)])
    }
    /// `expired`: history retention took the record, so the day, week and month notes above its block are frozen
    /// (kept as written) instead of deleted (LevelNotes.swift).
    func purgeActionDerivatives(_ id:String,expired:Bool=false) throws {
        // Every record removal (delete, retention, import deletion) takes the
        // typed words and stub with it.
        try deleteTypedWithinTransaction(id)
        try dropLevels(forActions:[id],expired:expired)
        if try hasMemoryControls() {
            try exec("DELETE FROM user_corrections WHERE EXISTS(SELECT 1 FROM json_each(user_corrections.body,'$.actionIDs') WHERE value=?)",[id])
        }
        guard try hasActionLayers() else { return }
        try exec("DELETE FROM generated_notes WHERE EXISTS (SELECT 1 FROM json_each(generated_notes.body,'$.actionIDs') WHERE value=?)",[id])
        try exec("DELETE FROM note_requests WHERE body<>'' AND EXISTS (SELECT 1 FROM json_each(note_requests.body,'$.actionIDs') WHERE value=?)",[id])
        try exec("DELETE FROM action_group_edits WHERE action_id=?",[id])
    }
    /// `purgeActionDerivatives` for many actions in one pass each (Forget a time range). Besides the blocks (and the
    /// notes above them), any level note that lists one of `ids` goes too, whatever its level, so no summary written
    /// from a forgotten action survives a broken edge.
    func purgeActionDerivatives(ids:[String]) throws {
        guard !ids.isEmpty else { return }
        let list=try json(Array(Set(ids)).sorted())
        if try hasTypedTables() {
            try exec("DELETE FROM typed_text WHERE id IN (SELECT value FROM json_each(?))",[list])
            try exec("DELETE FROM typed_after WHERE id IN (SELECT value FROM json_each(?))",[list])
            try dropTypedRecipients(ids)
        }
        try dropLevels(forActions:ids)
        if try hasLevelNotes() {
            let citing=try rows("SELECT id FROM level_notes WHERE json_valid(body) AND EXISTS(SELECT 1 FROM json_each(level_notes.body,'$.actionIDs') r JOIN json_each(?) c ON r.value=c.value)",[list]).map { $0[0] }
            for id in citing where try !rows("SELECT 1 FROM level_notes WHERE id=?",[id]).isEmpty { try dropLevel(id,expired:false) }
        }
        if try hasMemoryControls() {
            try exec("DELETE FROM user_corrections WHERE EXISTS(SELECT 1 FROM json_each(user_corrections.body,'$.actionIDs') r JOIN json_each(?) c ON r.value=c.value)",[list])
        }
        guard try hasActionLayers() else { return }
        try exec("DELETE FROM generated_notes WHERE EXISTS(SELECT 1 FROM json_each(generated_notes.body,'$.actionIDs') r JOIN json_each(?) c ON r.value=c.value)",[list])
        try exec("DELETE FROM note_requests WHERE body<>'' AND EXISTS(SELECT 1 FROM json_each(note_requests.body,'$.actionIDs') r JOIN json_each(?) c ON r.value=c.value)",[list])
        try exec("DELETE FROM action_group_edits WHERE action_id IN (SELECT value FROM json_each(?))",[list])
    }
    /// gold/notes G20: notes and writer requests that cite any of `ids`, and only those. A correction changes the
    /// inputs of the moments and days holding its actions, never any other note.
    func invalidateNotes(citing ids:[String]) throws {
        guard try hasActionLayers(), !ids.isEmpty else { return }
        let list=try json(Array(Set(ids)).sorted())
        try dropLevels(forActions:ids)
        try exec("DELETE FROM generated_notes WHERE EXISTS(SELECT 1 FROM json_each(generated_notes.body,'$.actionIDs') r JOIN json_each(?) c ON r.value=c.value)",[list])
        try exec("UPDATE note_requests SET state='invalidated',body='' WHERE body<>'' AND json_valid(body) AND EXISTS(SELECT 1 FROM json_each(note_requests.body,'$.actionIDs') r JOIN json_each(?) c ON r.value=c.value)",[list])
    }
    /// claude/catchup-1003: moments of today and the `days` days before it that have no note for what they hold now,
    /// which is what `status` and `doctor` call pending (before, they counted record summaries, which read 0 while two
    /// days of moments waited). `waiting`: no note at all; `updating`: an earlier note is still shown (stale-while-
    /// updating) until it is rewritten; `tooLong`: more actions than the writer reads, never written. Idle-only moments
    /// (the writer's `nothingToWrite`) aren't counted. Read only; `byDay` holds the days with any waiting or updating.
    public struct NoteBacklog: Equatable, Sendable {
        public var waiting=0, updating=0, tooLong=0, ready=0, partialDays=0
        public var byDay:[String:Int]=[:]
        public var pending:Int { waiting + updating }
    }
    public static let noteBacklogTooLong=2000
    public func noteBacklog(now:Date=Date(), timezone:String=TimeZone.current.identifier, days:Int=7) throws -> NoteBacklog {
        guard try hasActionLayers(), let zone=TimeZone(identifier:timezone) else { return NoteBacklog() }
        var calendar=Calendar(identifier:.gregorian); calendar.timeZone=zone
        var result=NoteBacklog()
        for back in 0...max(0,days) {
            guard let date=calendar.date(byAdding:.day,value:-back,to:now) else { continue }
            let day=try DayScope.key(date,timezone:timezone)
            let assembled=try assembleDay(day:day,timezone:timezone,limit:1,now:now,notes:true)
            guard !assembled.day.partial else { result.partialDays += 1; continue }
            var open=0
            for activity in assembled.day.activities {
                if activity.status == "ready" { result.ready += 1; continue }
                guard activity.status == "pending" else { continue }
                if activity.actionIDs.count > Self.noteBacklogTooLong { result.tooLong += 1; continue }
                let noApp=(activity.bundles ?? [""]).isEmpty && activity.apps.allSatisfy { $0.isEmpty }
                let idleOnly=activity.actionIDs.count <= 64 && activity.actionIDs.allSatisfy { id in
                    assembled.actions[id].map { ["idle","session.started","session.ended"].contains($0.kind) } ?? false
                }
                if noApp || idleOnly { continue }
                if activity.previous != nil { result.updating += 1 } else { result.waiting += 1 }
                open += 1
            }
            if open > 0 { result.byDay[day]=open }
        }
        return result
    }
    func invalidateAllNotes() throws {
        try dropAllLevels()
        guard try hasActionLayers() else { return }
        try exec("DELETE FROM generated_notes")
        try exec("UPDATE note_requests SET state='invalidated',body=''")
    }
}

/// What a cloud request for a note target would hold (gold/notes G25): its member actions without browser ones, as
/// `prepareNote(audience:.cloud)` picks them (counted without Return/shortcut markers, N18), and the earliest of their times (`.distantPast` when one can't be read).
public struct CloudNoteScope: Sendable, Equatable {
    public let actionCount:Int
    public let earliest:Date?
}
/// A cheap mark of what a past day's note work depends on besides its own actions (gold/notes G19).
public struct WriterDayMark: Sendable, Equatable {
    fileprivate let epoch:String, policy:String, notes:String
    fileprivate let highWater:Int64
}
extension MemoryStore {
    /// Per moment id and for the whole day, from the cached day assembly. Read only.
    public func cloudNoteScopes(day:String,timezone:String,now:Date=Date()) throws -> (activities:[String:CloudNoteScope],day:CloudNoteScope) {
        let assembled=try assembleDay(day:day,timezone:timezone,limit:1,now:now,notes:false)
        func scope<S:Sequence>(_ ids:S) -> CloudNoteScope where S.Element == String {
            var count=0, earliest:Date?
            for id in ids {
                guard let action=assembled.actions[id], NoteAudience.cloudEligible(action) else { continue }
                // N18: marker rows are sent but don't count toward the limit; their time still counts.
                if !NoteAudience.cloudMarker(kind:action.kind) { count += 1 }
                let time=timestamp(action.at) ?? .distantPast
                earliest=min(earliest ?? time, time)
            }
            return CloudNoteScope(actionCount:count,earliest:earliest)
        }
        var activities=[String:CloudNoteScope]()
        for activity in assembled.day.activities { activities[activity.id]=scope(activity.actionIDs) }
        return (activities,scope(assembled.day.activities.lazy.flatMap(\.actionIDs)))
    }
    /// Take before reading a day; `writerDayChanged` then says whether anything that day's targets depend on moved.
    public func writerDayMark() throws -> WriterDayMark {
        let policy=try rows("SELECT body FROM metadata WHERE id='policy'").first?.first ?? ""
        let notes=try hasActionLayers() ? (try rows("SELECT count(*),coalesce(max(rowid),0) FROM generated_notes").first ?? []).joined(separator:"|") : ""
        let top=Int64(try rows("SELECT coalesce(max(rowid),0) FROM records").first?.first ?? "0") ?? 0
        return WriterDayMark(epoch:try actionReadEpoch(),policy:policy,notes:notes,highWater:top)
    }
    /// False only when the read epoch, the policy and the notes are as marked and no record for `day` was added since.
    /// (Changing or deleting a record moves the epoch; a new one is found by id, never by scanning the table.)
    public func writerDayChanged(day:String,timezone:String,since mark:WriterDayMark) throws -> Bool {
        let current=try writerDayMark()
        guard current.epoch == mark.epoch, current.policy == mark.policy, current.notes == mark.notes, current.highWater >= mark.highWater else { return true }
        guard current.highWater > mark.highWater else { return false }
        let interval=try DayScope.interval(day:day,timezone:timezone)
        return try !rows("SELECT 1 FROM records WHERE rowid>? AND julianday(json_extract(body,'$.at'))>=julianday(?) AND julianday(json_extract(body,'$.at'))<julianday(?) LIMIT 1",
                         [String(mark.highWater),Self.actionBound(interval.start),Self.actionBound(interval.end)]).isEmpty
    }
}
