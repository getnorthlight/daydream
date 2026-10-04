import Foundation

/// Public presentation of a canonical source record. Raw evidence stays private.
public struct CanonicalAction: Codable, Equatable, Identifiable {
    public var id:String
    public var evidenceIDs:[String]
    public var at:String
    public var kind:String
    public var app:String
    public var bundle:String
    public var site:String
    public var title:String
    public var description:String
    public var state:String
    public var revision:String
    public var subject:String
    public var observationKey:String
    public var observedDescription:String? = nil
    public var observedState:String? = nil
    public var correction:UserCorrection? = nil
    /// claude/int-1003: `Evidence.titleTool`, the AI coding tool the title's dropped status glyph named ("" a spinner).
    public var tool:String? = nil
    /// page-links-1003: a Chrome page row's own link (`Evidence.page`, as `Privacy.sanitized` keeps it), for the app's own
    /// rows on this Mac (the short link beside a page, its open target). Display only: never encoded (no MCP, CLI or
    /// consumer reply carries it), never part of `==`, `revision` or `observationKey`.
    public var link:String? = nil
    private enum CodingKeys:String,CodingKey {
        case id,evidenceIDs,at,kind,app,bundle,site,title,description,state,revision,subject,observationKey,observedDescription,
             observedState,correction,tool
    }
    public static func == (a:CanonicalAction,b:CanonicalAction) -> Bool {
        a.id == b.id && a.evidenceIDs == b.evidenceIDs && a.at == b.at && a.kind == b.kind && a.app == b.app && a.bundle == b.bundle
            && a.site == b.site && a.title == b.title && a.description == b.description && a.state == b.state && a.revision == b.revision
            && a.subject == b.subject && a.observationKey == b.observationKey && a.observedDescription == b.observedDescription
            && a.observedState == b.observedState && a.correction == b.correction && a.tool == b.tool
    }
}
public struct ActionPage: Codable {
    public var actions:[CanonicalAction]
    public var next:String?
    public var revision:String
    public var snapshot:ActionSnapshot
    public var candidates:Int
}
public struct ActionSnapshot: Codable, Equatable {
    public var epoch:String
    public var highWater:Int64
}
public struct CurrentActions: Codable {
    public var status:String
    public var generatedAt:String
    public var observedAt:String?
    public var actions:[CanonicalAction]
    public var revision:String
    public var limitations:[String]
    public var truncated:Bool
    public var continuation:String?
    public var windowStart:String
    public var windowEnd:String
    public var candidates:Int
}
/// Must originate at a verified native/connector delivery boundary, never a key event.
/// No current recorder creates this proof. Adding a producer needs its own tests.
public struct SendVerification: Codable, Equatable {
    public var evidenceID:String
    public var messageID:String
    public var source:String
    public var confirmedAt:String
    public init(evidenceID:String,messageID:String,source:String,confirmedAt:String) {
        self.evidenceID=evidenceID; self.messageID=messageID; self.source=source; self.confirmedAt=confirmedAt
    }
    public func verifies(_ evidence:Evidence) -> Bool {
        evidence.kind == "message.sent" && evidenceID == evidence.id && !messageID.isEmpty && messageID.count <= 200 &&
        ["native-delivery-receipt","connector-send-result"].contains(source) &&
        timestamp(confirmedAt).flatMap { confirmation in timestamp(evidence.at).map { abs(confirmation.timeIntervalSince($0)) <= 5 } } == true
    }
}
public enum ActionProjection {
    // v4 invalidates old search projections that borrowed a Messages title.
    public static let version="canonical-action-v4"
    public static func make(_ e:Evidence) -> CanonicalAction {
        var state="observed", description:String
        switch e.kind {
        case "browser.observed", "browser.extension_observed": description="Observed a foreground browser context in \(e.app); reading is not established."
        case "browser.extension_tab_visited":
            state=BrowserSafety.valid(e) ? "observed" : "unavailable"
            description=state == "observed" ? "Observed a continuous foreground tab visit in \(e.app); reading is not established." : "Browser action unavailable: verified capture evidence is missing."
        case "message.sent":
            if e.sendVerification?.verifies(e) == true { state="sent"; description="Message send confirmed in \(e.app)." }
            else { state="unverified"; description="Unverified message observation in \(e.app); sending is not established." }
        case "keyboard.submit": state="draft"; description="Pressed Return in \(e.app); sending is not established."
        case "keyboard.text_input":
            // summaries/v3 (spec §2): a unit whose send key code detected at seal time is "submitted" (a send gesture,
            // not a delivery: "sent" stays receipt-only). Rows without the fact (typed-unit/v2) stay "draft" and keep
            // their exact description, so their revisions never move.
            let submitted=e.captureProvenance?.unit?.send == "detected"
            state=submitted ? "submitted" : "draft"
            // fix/chrome-capture: a proven click on the composer's Post or Reply button says so (still "submitted", never sent).
            let button=submitted && e.captureProvenance?.unit?.sendBy == "button"
            let control=e.captureProvenance?.unit?.sendControl
            // terminal-1002: a terminal line sealed by Return is the only "code" unit with a detected send: it ran.
            let ran=submitted && e.captureProvenance?.unit?.surface == "code"
            let describe:(String,Int)->String=button ? { TypedWords.buttonDescription(app:$0,control:control ?? "",words:$1) }
                : ran ? TypedWords.ranDescription : submitted ? TypedWords.submittedDescription : TypedWords.actionDescription
            // Sealed rows carry no words: a word-count bucket only. Build 4
            // plain-text rows waiting for the upgrade get the same bucket, so
            // no writer or AI app reads their words either. The description
            // never changes when words expire, so note revisions stay stable.
            if let typed=e.typed, e.text.isEmpty { description=describe(e.app,typed.words) }
            else if !e.text.isEmpty { description=describe(e.app,TypedWords.count(e.text)) }
            else if button { description="Typed in \(e.app), then clicked its \(TypedWords.controlName(control)) button." }
            else if ran { description="Ran a command in \(e.app)." }
            else { description=submitted ? "Typed in \(e.app), then used its send key." : "Typed a draft in \(e.app)." }
        case "selection.changed", "terminal.value_changed": description="Observed text in \(e.app); authorship is not established."
        case "window.changed", "window.observed", "focus.observed", "browser.snapshot":
            description="Observed \(e.title.isEmpty ? "a window" : e.title) in \(e.app); reading is not established."
            if let query=URLComponents(string:e.url)?.percentEncodedQueryItems?.first(where:{["q","query","search_query"].contains($0.name)})?.value, !query.isEmpty {
                description="Observed search results for \(Privacy.clean(Privacy.searchValue(query),limit:160)) in \(e.app); submission and reading are not established."
            }
            if e.browserVerification?.provider == BrowserSafety.pageProvider, let host=URL(string:e.url)?.host, !host.isEmpty {
                description=e.title.isEmpty ? "Observed \(host) in \(e.app); reading is not established." : "Observed \(e.title) on \(host) in \(e.app); reading is not established."
            }
        case "browser.tab_opened", "browser.tab_visited":
            let supported=e.synthetic || BrowserSafety.valid(e)
            state=supported ? "observed" : "unavailable"
            description=supported ? (e.browserVerification?.provider == "chrome-native-bridge-v1" ? "Observed a continuous foreground tab visit in \(e.app); reading is not established." : "\(e.kind == "browser.tab_opened" ? "Opened" : "Revisited") tab \(e.title) in \(e.app).") : "Browser action unavailable: verified capture evidence is missing."
        case "idle": state="idle"; description="Idle was observed; no reading or work duration is established."
        default: let item=IntentWriter.write(e); state=item.actionState; description=item.summary
        }
        // B2: source evidence keeps its window metadata, but an unclassified
        // Messages typed field cannot hand a stale chat name to a note writer.
        let messagesTyped=e.kind == "keyboard.text_input" && MessagesMomentIdentity.applies(bundle:e.bundle,app:e.app)
        let title=messagesTyped
            ? MessagesMomentIdentity.recipient(e.captureProvenance?.unit) ?? "Messages" : e.title
        let subject=Privacy.clean(title,limit:160)
        var action=CanonicalAction(id:e.id,evidenceIDs:[e.id],at:e.at,kind:e.kind,app:e.app,bundle:e.bundle,
            site:URL(string:e.url)?.host ?? "",title:title,description:description,state:state,
            // K3: unaffected evidence retains its exact canonical revision.
            revision:fingerprint((messagesTyped ? version : "canonical-action-v3") + ((try? json(e)) ?? e.id)),subject:subject,
            observationKey:fingerprint((try? json([e.kind,e.app,e.bundle,e.title,e.url,e.text]+(e.typed.map{[$0.digest]} ?? []))) ?? e.id))
        action.tool=e.titleTool
        // page-links-1003: a Chrome page row's own link, for the app's rows only (never encoded).
        if e.browserVerification?.provider == BrowserSafety.pageProvider, let page=e.page, !page.isEmpty { action.link=page }
        return action
    }
    public static func coalescible(_ action:CanonicalAction) -> Bool {
        ["window.observed","focus.observed","browser.snapshot"].contains(action.kind)
    }
}
private struct ActionCursor: Codable {
    var at:String; var id:String; var revision:String; var scope:String; var snapshot:ActionSnapshot
}
private struct CurrentCursor:Codable { var start:Date; var end:Date; var after:String }
private func actionTime(_ date:Date) -> String {
    let formatter=ISO8601DateFormatter(); formatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
    return formatter.string(from:date)
}
extension MemoryStore {
    func permittedOriginal(_ id:String,now:Date) throws -> Evidence? {
        guard try rows("SELECT id FROM tombstones WHERE id=?",[id]).isEmpty,
              let body=try rows("SELECT body FROM records WHERE id=?",[id]).first?.first else { return nil }
        return Privacy.sanitized(try decode(Evidence.self,body),settings:try policy(),now:now)
    }
    /// This read never consults generated summaries or a search service.
    public func action(_ id:String,now:Date=Date()) throws -> CanonicalAction? {
        let revision=try actionReadEpoch()
        guard let permitted=try permittedOriginal(id,now:now) else { return nil }
        let result=try Self.applying(try latestCorrection(kind:"action",targetID:id),to:ActionProjection.make(permitted))
        guard try revision == actionReadEpoch() else { throw MemError.invalid("Actions changed; retry fresh read") }
        return result
    }
    /// An action's latest correction, applied the one way both `action(_:)` and the day assembly use (gold/notes G15).
    static func applying(_ correction:UserCorrection?,to action:CanonicalAction) throws -> CanonicalAction {
        guard let correction, let text=correction.text else { return action }
        var result=action
        result.observedDescription=result.description; result.description="User correction (not observed): "+text
        result.observedState=result.state; result.state="user_corrected"
        result.correction=correction; result.revision=fingerprint(result.revision+(try json(correction)))
        return result
    }
    public func actions(start:Date?=nil,end:Date?=nil,app:String?=nil,after:String?=nil,limit:Int=100,now:Date=Date(),snapshot:ActionSnapshot?=nil,descending:Bool=false) throws -> ActionPage {
        let revision=try actionReadEpoch(), size=max(1,min(200,limit))
        let fence=try snapshot ?? ActionSnapshot(epoch:revision,highWater:Int64(rows("SELECT coalesce(max(rowid),0) FROM records").first!.first!) ?? 0)
        guard fence.epoch == revision else { throw MemError.invalid("Snapshot invalidated; restart pagination") }
        let scope=actionScope(start:start,end:end,app:app,descending:descending)
        var cursor=ActionCursor(at:descending ? "9999-12-31T00:00:00Z" : "0001-01-01T00:00:00Z",id:descending ? "\u{10ffff}" : "",revision:revision,scope:scope,snapshot:fence)
        if let after {
            guard after.utf8.count < 4096, let data=Data(base64Encoded:after), let value=try? JSONDecoder().decode(ActionCursor.self,from:data), value.revision == revision, value.snapshot.epoch == revision, value.scope == scope, snapshot == nil || value.snapshot == snapshot else { throw MemError.invalid("Stale or invalid action cursor; restart pagination") }
            cursor=value
        }
        let candidates=try actionCandidates(fence:cursor.snapshot.highWater,cursor:(cursor.at,cursor.id),fromCursor:after != nil,
                                            start:start.map(actionTime) ?? "0001-01-01T00:00:00Z",end:end.map(actionTime) ?? "9999-12-31T00:00:00Z",
                                            app:app ?? "",descending:descending,limit:size+1)
        let batch=Array(candidates.prefix(size))
        let result=try batch.compactMap { row -> CanonicalAction? in
            guard let value=try action(row[0],now:now), app == nil || app == value.app || app == value.bundle else { return nil }
            return value
        }
        guard try revision == actionReadEpoch() else { throw MemError.invalid("Actions changed; retry fresh read") }
        let next=try batch.last.flatMap { last in candidates.count > size ? Data(try json(ActionCursor(at:last[1],id:last[0],revision:revision,scope:scope,snapshot:cursor.snapshot)).utf8).base64EncodedString() : nil }
        return ActionPage(actions:result,next:next,revision:revision,snapshot:cursor.snapshot,candidates:batch.count)
    }
    /// Rows of the time index one statement of an `actions` page filtered by app may read past its position (gold
    /// r2-store-perf). Every other page reads at most `limit` rows in one statement.
    static let actionWindow=1000
    /// The first `limit` rows after the cursor (id, time), in `actions` order, rowid up to `fence`, within
    /// [`start`, `end`) and of `app` when not empty: exactly what one statement of the whole range returned before.
    /// Each statement is bounded on both sides by the time index (`records_at_julian`), so it reads only its own rows;
    /// the locks are free between statements. With an app filter a statement stops only once it has `limit` rows of
    /// that app, so for an app seldom used it would read the whole range: it reads a window at a time instead (the
    /// rows up to the time of the `actionWindow`th row past the position). Without the time index, one statement as
    /// before (each statement would scan the whole table).
    private func actionCandidates(fence:Int64,cursor:(at:String,id:String),fromCursor:Bool,start:String,end:String,app:String,descending:Bool,limit:Int) throws -> [[String]] {
        let jd=Self.dayTime, comparison=descending ? "<" : ">", order=descending ? "DESC" : "ASC"
        let appFilter=" AND (?='' OR json_extract(body,'$.app')=? OR json_extract(body,'$.bundle')=?)"
        // The cursor condition exactly as before.
        let after="(\(jd)\(comparison)julianday(?) OR (\(jd)=julianday(?) AND id\(comparison)?))"
        guard try timeIndexed() else {
            return try rows("SELECT id,json_extract(body,'$.at') FROM records WHERE rowid<=? AND \(after) AND \(jd)>=julianday(?) AND \(jd)<julianday(?)\(appFilter) ORDER BY \(jd) \(order),id \(order) LIMIT ?",
                            [String(fence),cursor.at,cursor.at,cursor.id,start,end,app,app,app,String(limit)])
        }
        /// Where a statement starts: the cursor, or past every row at a window's edge (`past`).
        enum Position { case cursor(String,String), past(String) }
        // The rows past `position` up to `edge` (inclusive; nil: to the range's end), bounded on both sides by the index:
        // one bound term per side for the index, the others (`+`, which the index can't use) only filter.
        func bounded(_ position:Position,edge:String?) -> (sql:String,values:[String]) {
            var sql=Self.rowidFence("<="), values=[String(fence)]
            let near:(String,[String]), far:(String,[String])
            switch position {
            case let .cursor(at,id):
                // From the cursor when it was given (its row is in the range); from the range's side for a first page.
                let cursorSide=descending ? "\(jd)<=julianday(?)" : "\(jd)>=julianday(?)", rangeSide=descending ? "\(jd)<julianday(?)" : "\(jd)>=julianday(?)"
                let rangeValue=descending ? end : start
                near=fromCursor ? (cursorSide+" AND +"+rangeSide,[at,rangeValue]) : (rangeSide+" AND +"+cursorSide,[rangeValue,at])
                sql += " AND "+after; values += [at,at,id]
            case let .past(at):
                near=(descending ? "\(jd)<julianday(?)" : "\(jd)>julianday(?)",[at])
                sql += " AND +"+(descending ? "\(jd)<julianday(?)" : "\(jd)>=julianday(?)"); values += [descending ? end : start]
            }
            let rangeFar=descending ? "\(jd)>=julianday(?)" : "\(jd)<julianday(?)", farValue=descending ? start : end
            if let edge { far=((descending ? "\(jd)>=julianday(?)" : "\(jd)<=julianday(?)")+" AND +"+rangeFar,[edge,farValue]) }
            else { far=(rangeFar,[farValue]) }
            return (sql+" AND "+near.0+" AND "+far.0,values+near.1+far.1)
        }
        let select="SELECT id,json_extract(body,'$.at') FROM records WHERE ", ordered=" ORDER BY \(jd) \(order),id \(order) LIMIT ?"
        var position=Position.cursor(cursor.at,cursor.id), found=[[String]]()
        guard !app.isEmpty else {
            let range=bounded(position,edge:nil)
            return try rows(select+range.sql+appFilter+ordered,range.values+[app,app,app,String(limit)])
        }
        while found.count < limit {
            // This window's edge: the time of the `actionWindow`th row past the position (nil: fewer are left). The
            // index alone answers it (ordered by time only: every row at the edge's time is in the window).
            let range=bounded(position,edge:nil)
            let edge=try rows("SELECT json_extract(body,'$.at') FROM records WHERE "+range.sql+" ORDER BY \(jd) \(order) LIMIT 1 OFFSET ?",
                              range.values+[String(Self.actionWindow)]).first?.first
            let window=bounded(position,edge:edge)
            found += try rows(select+window.sql+appFilter+ordered,window.values+[app,app,app,String(limit-found.count)])
            // Every row up to the edge's time was read: the next window starts past it.
            guard found.count < limit, let edge else { break }
            position = .past(edge)
            letWaitersInBetweenReads()
        }
        return found
    }
    private func actionScope(start:Date?,end:Date?,app:String?,descending:Bool) -> String {
        fingerprint("\(start?.timeIntervalSince1970.description ?? "")|\(end?.timeIntervalSince1970.description ?? "")|\(app ?? "")|\(descending)")
    }
    /// The bound `actions(start:end:)` compares with, for readers that scan the same range in one query.
    static func actionBound(_ date:Date) -> String { actionTime(date) }
    /// Exactly the first page `actions(start:end:limit:now:)` returns (ascending, all apps, no cursor), built from
    /// candidate rows the caller already read in the same order under `snapshot`: every row in the range with
    /// rowid <= snapshot.highWater, `action` nil where the policy hides it (gold/notes G15: the day is read once).
    func firstActionPage(start:Date,end:Date,limit:Int,snapshot:ActionSnapshot,candidates:ArraySlice<(id:String,at:String,action:CanonicalAction?)>) throws -> ActionPage {
        let size=max(1,min(200,limit)), scope=actionScope(start:start,end:end,app:nil,descending:false)
        let batch=Array(candidates.prefix(size))
        let next=try batch.last.flatMap { last in candidates.count > size ? Data(try json(ActionCursor(at:last.at,id:last.id,revision:snapshot.epoch,scope:scope,snapshot:snapshot)).utf8).base64EncodedString() : nil }
        return ActionPage(actions:batch.compactMap(\.action),next:next,revision:snapshot.epoch,snapshot:snapshot,candidates:batch.count)
    }
    /// Exactly the page `actions(start:end:after:limit:now:)` returns for `after`, built from the same candidate rows
    /// (every row in the range, in order, with rowid <= the cursor's high-water mark). nil when the cursor's row is
    /// not among them; the caller then asks `actions` itself. A stale or foreign cursor fails as it does there.
    func actionPage(after:String,start:Date,end:Date,limit:Int,candidates:[(id:String,at:String,action:CanonicalAction?)]) throws -> ActionPage? {
        let revision=try actionReadEpoch(), scope=actionScope(start:start,end:end,app:nil,descending:false)
        guard after.utf8.count < 4096, let data=Data(base64Encoded:after), let value=try? JSONDecoder().decode(ActionCursor.self,from:data), value.revision == revision, value.snapshot.epoch == revision, value.scope == scope else { throw MemError.invalid("Stale or invalid action cursor; restart pagination") }
        guard let index=candidates.firstIndex(where:{ $0.id == value.id && $0.at == value.at }) else { return nil }
        let rest=candidates[(index+1)...].prefix(max(1,min(200,limit))+1)
        return try firstActionPage(start:start,end:end,limit:limit,snapshot:value.snapshot,candidates:rest)
    }
    /// The high-water mark a cursor pins, once it is known to be this store's current one.
    func actionCursorHighWater(_ after:String) -> Int64? {
        guard after.utf8.count < 4096, let data=Data(base64Encoded:after), let value=try? JSONDecoder().decode(ActionCursor.self,from:data) else { return nil }
        return value.snapshot.highWater
    }
    /// A cursor for an ascending, all-apps page that resumes right after action
    /// `id`, for readers that stop partway through a page they fetched.
    func actionCursor(start:Date?,end:Date?,snapshot:ActionSnapshot,after id:String) throws -> String? {
        let revision=try actionReadEpoch()
        guard snapshot.epoch == revision, let at=try rows("SELECT json_extract(body,'$.at') FROM records WHERE id=?",[id]).first?.first else { return nil }
        let cursor=ActionCursor(at:at,id:id,revision:revision,scope:actionScope(start:start,end:end,app:nil,descending:false),snapshot:snapshot)
        return Data(try json(cursor).utf8).base64EncodedString()
    }
    public func currentActions(now:Date=Date(),after:String?=nil) throws -> CurrentActions {
        let revision=try actionReadEpoch(), capture=try captureStatus(now:now)
        var start=now.addingTimeInterval(-30), end=now.addingTimeInterval(0.001), cursor:String?
        if let after {
            guard after.utf8.count < 8192, let data=Data(base64Encoded:after), let value=try? JSONDecoder().decode(CurrentCursor.self,from:data), value.end.timeIntervalSince(value.start) <= 31, value.start <= value.end, value.end <= now.addingTimeInterval(1), now.timeIntervalSince(value.end) < 300 else { throw MemError.invalid("Expired or invalid current-context cursor") }
            start=value.start; end=value.end; cursor=value.after
        }
        let page=try actions(start:start,end:end,after:cursor,limit:10,now:now,descending:true)
        let sample=page.actions
        // Synthetic demo remains explicitly labelled, never promoted to live status.
        let synthetic = try !sample.isEmpty && sample.allSatisfy { action in
            guard let body=try rows("SELECT body FROM records WHERE id=?",[action.id]).first?.first else { return false }
            return try decode(Evidence.self,body).synthetic
        }
        let captureState=capture["state"] ?? "off"
        let status = synthetic && captureState == "off" ? "synthetic_demo_not_live" : captureState != "recording" ? "capture_"+captureState : sample.isEmpty || now.timeIntervalSince(end) > 30 ? "stale" : "recent_observations"
        let eligible=(captureState == "recording" || status == "synthetic_demo_not_live") ? Array(sample.prefix(10)) : []
        guard try revision == actionReadEpoch(), try captureStatus(now:now)["state"] == capture["state"] else { throw MemError.invalid("Current context changed; retry") }
        let canContinue=captureState == "recording" || status == "synthetic_demo_not_live"
        let continuation=try canContinue ? page.next.map { Data(try json(CurrentCursor(start:start,end:end,after:$0)).utf8).base64EncodedString() } : nil
        return CurrentActions(status:status,generatedAt:iso(now),observedAt:eligible.first?.at,actions:eligible,revision:revision,
            limitations:["Shows what was in front and typed in the last 30 seconds, not what was read, how long anything took, or whether it is still happening.","Only state \"sent\" confirms that a message was sent; Return presses and typed text are drafts.","Up to 10 records per page. Pass continuation as after for the next page; each page is a snapshot, not a live screen."],truncated:canContinue && page.next != nil,continuation:continuation,windowStart:actionTime(start),windowEnd:actionTime(end),candidates:canContinue ? page.candidates : 0)
    }
}
