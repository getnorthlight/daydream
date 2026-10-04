import Foundation
import MemoryCore
import WriterBackend

/// Compile into the native app integration target, not WriterBackend. No process,
/// Python, network, credentials or automatic writer execution is involved.
public actor CoreWriterBinding {
    private let store:MemoryStore
    private var requests:[String:NoteWriterRequest]=[:]
    private var selfNames:[String]=[],selfNamesAt:Date?
    /// Which writer this binding serves, for typed words: `.local` (the writer
    /// on this Mac) reads them while typing is on; `.cloud` never does.
    /// Unknown counts as cloud, the stricter rule.
    private let typedWriter:TypedWriterKind
    public init(store:MemoryStore,typedWriter:TypedWriterKind = .cloud) { self.store=store; self.typedWriter=typedWriter }
    /// The most typed characters one row hands a writer (ModelView.typedQuoteChars).
    public static let typedWordsLimit=1600
    private func wire<T:Decodable,U:Encodable>(_ value:U,_ type:T.Type) throws -> T {
        try JSONDecoder().decode(type,from:JSONEncoder().encode(value))
    }
    /// A port for the cloud audience is always the cloud writer for typed
    /// words too, whatever kind this binding was made for (the stricter rule).
    private func writerKind(_ audience:NoteAudience) -> TypedWriterKind { audience == .cloud ? .cloud : typedWriter }
    private func presentation(_ actions:[CanonicalAction], request:NoteWriterRequest, audience:NoteAudience) throws -> [NoteAction] {
        let kind=writerKind(audience)
        // fix/sx-all round 2: whether typing there would have been recorded (metadata): "Read texts with Mom" only then.
        let recordable=store.typingRecordableCheck()
        return try actions.map { action in
            var value=try wire(action,NoteAction.self)
            value.typing=recordable(action) ? "on" : nil
            // fix/typing-e2e + fix/day-card: a website typing row is titled with its page's title on this Mac; the cloud
            // gets that title cleaned (`NoteAudience.cloudView`), never an address, unread count or app suffix.
            if audience == .cloud { value.title=NoteAudience.cloudTitle(action) }
            // Safe typing: stored actions carry a word count only, so by default
            // the writer sees "typed text (not captured)". The words are added
            // here, in memory and in the app process only, for a writer the
            // typed-words disclosure allows while typing is on and the vault is
            // ready; at most 1,600 characters of the (already scrubbed) draft
            // (summaries/v3 spec §5). The view joins a run's pieces by runID.
            // Never stored.
            if action.kind == "keyboard.text_input", action.correction == nil,
               let words=try store.hydrateTypedText(action.id,disclosure:kind.disclosure), !words.isEmpty {
                value.description="Typed a draft in \(action.app). "+words.prefixString(Self.typedWordsLimit)
            }
            // prompt7 send facts code decided at seal time (metadata, never words): the view's surface, "sent with ..."
            // ending, "Start with:" leads and recipient come from these, never from the model.
            if action.kind == "keyboard.text_input", let unit=try store.typedUnit(action.id,disclosure:kind.disclosure) {
                value.surface=unit.surface;value.send=unit.send;value.sendBy=unit.sendBy;value.to=unit.to;value.pasted=unit.pasted
                value.runID=unit.runID.isEmpty ? nil : unit.runID
                value.field=unit.field
                // claude/messages2-1003: what sealed the unit (a Messages text sealed by Return is a whole text).
                value.seal=unit.sealReason.isEmpty ? nil : unit.sealReason
                // compose-send/v1: the gesture's control, its confirmation, and the identity adapter's destination and
                // replied-to context (page metadata: the parent post's author and excerpt, never the typed words).
                value.sendControl=unit.sendControl;value.confirm=unit.confirm;value.handle=unit.handle;value.community=unit.community
                value.subject=unit.subject;value.contextAuthor=unit.contextAuthor;value.contextExcerpt=unit.contextExcerpt
            }
            // C5 (summaries/v3): typed rows keep their place label for the cloud
            // too; a Mail subject is the thread, and the words themselves follow
            // the typed-words disclosure above.
            let notes=(request.corrections ?? []).filter { $0.actionIDs.contains(action.id) && $0.targetKind != "action" && $0.text != nil }
            // Provider schema currently lacks corrections. Preserve their meaning
            // in its canonical presentation, never rewrite immutable observations.
            if action.correction != nil || !notes.isEmpty { value.state="reported" }
            for correction in notes {
                value.description += "\nUser correction to related note (not observed evidence): " + correction.text!
            }
            guard value.description.utf8.count<=16000 else { throw MemError.invalid("Corrected writer presentation exceeds bound") }
            return value
        }
    }
    private func prepare(_ target:WriterTarget,audience:NoteAudience) throws -> CanonicalNoteRequest {
        requests=requests.filter { timestamp($0.value.expiresAt).map{$0>Date()} == true }
        // fix/sx-engine-battery: a batch prepares up to a dozen notes in a few minutes, and a note that ended pending
        // (its answer failed the checks) is never cancelled here. At 32 the oldest prepared request is let go instead of
        // refusing the new one: a request no longer held is never permitted (fails closed), so the bound stays.
        while requests.count>=32, let oldest=requests.min(by:{ ($0.value.expiresAt,$0.key) < ($1.value.expiresAt,$1.key) })?.key {
            requests.removeValue(forKey:oldest)
        }
        let request=try store.prepareNote(kind:target.kind.rawValue,day:target.day,timezone:target.timezone,activityID:target.activityID,audience:audience,
            allowGrowingSnapshot:target.allowGrowingSnapshot && audience == .local && typedWriter == .local && target.kind == .activity)
        var result=try wire(request,CanonicalNoteRequest.self)
        result.actions=try presentation(request.actions,request:request,audience:audience)
        // fix/sx-all round 2: the person's own account names (mail window addresses): "Checked your PR #418", never "Reviewed".
        if selfNamesAt.map({ Date().timeIntervalSince($0) > 3600 }) ?? true { selfNames=store.accountHandles(); selfNamesAt=Date() }
        result.selfNames=selfNames.isEmpty ? nil : selfNames
        requests[request.id]=request
        return result
    }
    private func page(_ id:String,_ after:Int,audience:NoteAudience) throws -> WriterActionPage {
        guard let request=requests[id] else { throw MemError.invalid("Prepare writer request before paging") }
        let page=try store.noteActions(requestID:id,after:after)
        return WriterActionPage(actions:try presentation(page.actions,request:request,audience:audience),next:page.next,actionCount:page.actionCount)
    }
    private func permitted(_ request:CanonicalNoteRequest,_ actions:[NoteAction],audience:NoteAudience) -> Bool {
        do {
            guard let prepared=requests[request.id],prepared.inputRevision==request.inputRevision,
                  actions.count<=5000,Set(actions.map(\.id)).count==actions.count else { return false }
            // Recheck the actual provider presentation, not only revision strings.
            // fix/sx-all (fix/day-card owner decision 9/28): a cloud writer reads browser rows as `NoteAudience.cloudView`
            // shows them (host plus cleaned page title), exactly as prepare and page handed them over, so the recheck
            // compares like with like. The commit-time correction guard in DerivedNotes keeps the strict bundle rule.
            let current=try actions.map { item -> CanonicalAction in
                guard let action=try store.action(item.id) else { throw MemError.missing }
                return audience == .cloud ? NoteAudience.cloudView(action) : action
            }
            // A correction that covers browser activity never reaches the cloud (its text may come from those pages).
            if audience == .cloud {
                for id in (prepared.corrections ?? []).flatMap(\.actionIDs) {
                    guard let action=try store.action(id),NoteAudience.cloudEligible(bundle:action.bundle) else { return false }
                }
            }
            guard try json(presentation(current,request:prepared,audience:audience)) == json(actions) else { return false }
            try store.validatePreparedNote(request.id,revisions:Dictionary(uniqueKeysWithValues:actions.map{($0.id,$0.revision)}))
            return true
        } catch { return false }
    }
    private func commit(_ output:CanonicalNoteOutput) throws -> WriterCommitReceipt {
        let result=try store.commitNote(wire(output,NoteWriterOutput.self))
        return try wire(result,WriterCommitReceipt.self)
    }
    private func cancel(_ id:String) throws { try store.cancelNote(id); requests.removeValue(forKey:id) }
    /// `.cloud` prepares without browser actions and never permits one.
    public nonisolated func port(audience:NoteAudience = .local) -> CoreWriterPort {
        CoreWriterPort(prepare:{try await self.prepare($0,audience:audience)},page:{try await self.page($0,$1,audience:audience)},
                       commit:{try await self.commit($0)},cancel:{try await self.cancel($0)},
                       permitted:{await self.permitted($0,$1,audience:audience)})
    }
}
