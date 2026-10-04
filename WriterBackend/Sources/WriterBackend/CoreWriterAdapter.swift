import Foundation

/// Explicit caller-selected work only. This adapter never enumerates history.
public struct WriterTarget: Sendable {
    public enum Kind: String, Sendable { case activity, day }
    public let kind:Kind,day:String,timezone:String,activityID:String?
    /// Explicit local live-summary opt-in. Core still verifies privacy and permits
    /// only additive growth beyond the exact prepared action snapshot.
    public let allowGrowingSnapshot:Bool
    public init(kind:Kind,day:String,timezone:String,activityID:String?=nil,allowGrowingSnapshot:Bool=false) {
        self.kind=kind;self.day=day;self.timezone=timezone;self.activityID=activityID
        self.allowGrowingSnapshot=allowGrowingSnapshot
    }
}
public struct WriterActionPage: Codable, Sendable {
    public let actions:[NoteAction],next:Int?,actionCount:Int
    public init(actions:[NoteAction],next:Int?,actionCount:Int) {self.actions=actions;self.next=next;self.actionCount=actionCount}
}
/// Wire subset of core GeneratedNote. A core acknowledgement, not provider success.
public struct WriterCommitReceipt: Codable, Sendable {
    public let id:String,version:Int,inputRevision:String,status:String,output:CanonicalNoteOutput
    public init(id:String,version:Int,inputRevision:String,status:String,output:CanonicalNoteOutput) {
        self.id=id;self.version=version;self.inputRevision=inputRevision;self.status=status;self.output=output
    }
}
public struct CoreWriterPort: Sendable {
    public let prepare:@Sendable (WriterTarget) async throws -> CanonicalNoteRequest
    public let page:@Sendable (String,Int) async throws -> WriterActionPage
    /// Must call MemoryStore.commitNote. Never replace with a direct DB write.
    public let commit:@Sendable (CanonicalNoteOutput) async throws -> WriterCommitReceipt
    public let cancel:@Sendable (String) async throws -> Void
    public let permitted:CanonicalPolicyCheck
    public init(prepare:@escaping @Sendable (WriterTarget) async throws -> CanonicalNoteRequest,
                page:@escaping @Sendable (String,Int) async throws -> WriterActionPage,
                commit:@escaping @Sendable (CanonicalNoteOutput) async throws -> WriterCommitReceipt,
                cancel:@escaping @Sendable (String) async throws -> Void,
                permitted:@escaping CanonicalPolicyCheck) {
        self.prepare=prepare;self.page=page;self.commit=commit;self.cancel=cancel;self.permitted=permitted
    }
}
public struct PendingWriterNote: Sendable {
    /// fix/sx-engine-battery: the cloud failures a person fixes (`CloudFailure`) keep their kind, so the app shows the
    /// one line and button that fix it (SummaryProblem): the key, the credits, the host, or the connection.
    public enum Reason:String,Sendable {case capacity,providerUnavailable,invalidOutput,notSent,cloudKey,cloudCredits,cloudHost,cloudOffline}
    public let requestID:String,reason:Reason,actionIDs:[String],fallback:[GroundedBullet]
    public let derivation="action-quotes/v1"
    public var explanation:String {
        switch reason {
        case .capacity:return "This activity or day exceeds the writer's bounded output capacity. All actions remain available; its generated note is pending."
        case .providerUnavailable:return "The writer could not produce a validated note. All actions remain available; generation is pending."
        case .invalidOutput:return "The writer's answer did not pass the grounding checks, even after one repair. All actions remain available; its note is pending."
        case .notSent:return "The note request couldn't leave this Mac. It will be tried again."
        case .cloudKey:return "OpenRouter didn't accept the key. All actions remain available; the note waits for a working key."
        case .cloudCredits:return "The OpenRouter account is out of credits. All actions remain available; the note waits."
        case .cloudHost:return "OpenRouter has no zero-retention host for this model right now. All actions remain available; the note waits."
        case .cloudOffline:return "OpenRouter couldn't be reached. All actions remain available; it will be tried again."
        }
    }
}
public enum CoreWriterResult: Sendable {
    case committed(WriterCommitReceipt)
    /// This presentation fallback is never committed as a generated note.
    case pending(PendingWriterNote)
}
public typealias CanonicalGenerate = @Sendable (CanonicalNoteRequest,[NoteAction]) async throws -> CanonicalNoteOutput

public actor CoreWriterAdapter {
    /// MemoryStore.commitNote's copy-guard refusal (TypedTextRetention.swift typedVerbatimGuard).
    static func copyRefusal(_ error:Error)->Bool {String(describing:error).contains("may not copy what the person typed")}
    /// fix/summary-sends QF-14: MemoryStore.commitNote's claim refusals (DerivedNotes.swift). The same answer would be
    /// refused again (greedy decoding replays it), so the note ends pending with its code-written fallback (`invalidOutput`:
    /// final in local mode, Retry in cloud mode), never a provider retry. CanonicalGrounding.check mirrors the rule
    /// (`coreClaimProblem`), so this is the backstop for a rule the two ever disagree on.
    static let claimRefusals=["Send claim lacks verified delivery evidence","Send claim lacks a detected send","Draft claim has mismatched evidence",
                              "Unreferenced or invalid note claim","Corrected text is user-authored","Observation duration does not prove attention"]
    static func claimRefusal(_ error:Error)->Bool {let text=String(describing:error);return claimRefusals.contains {text.contains($0)}}
    private let core:CoreWriterPort,generate:CanonicalGenerate
    private let appNames:[String:String]
    private let localIntentSessions:Bool
    private var running=false
    /// `appNames` must be the map the writer was given: the final check rebuilds the same ITEMS view.
    public init(core:CoreWriterPort,generate:@escaping CanonicalGenerate,appNames:[String:String]=[:],localIntentSessions:Bool=false) {self.core=core;self.generate=generate;self.appNames=appNames;self.localIntentSessions=localIntentSessions}
    public func process(_ target:WriterTarget,lastActivity:Date,now:Date=Date(),allowActive:Bool=false) async throws -> CoreWriterResult {
        guard !running,allowActive || now.timeIntervalSince(lastActivity)>=2 else {throw WriterFailure.busy}
        guard target.kind != .activity || target.activityID?.isEmpty==false else {throw WriterFailure.invalidInput}
        running=true;defer{running=false}
        let core=self.core,generate=self.generate,appNames=self.appNames,localIntentSessions=self.localIntentSessions
        let work=Task.detached(priority:.background) { () async throws -> CoreWriterResult in
          // gold/notes G26: until `generate` is called nothing has left this Mac, so a failure before it (preparing,
          // paging, the pre-send checks) is `notSent`, which the app retries with backoff. Cancellation stays itself.
          var sent=false
          do {
            try Task.checkCancellation()
            let request=try await core.prepare(target)
            do {
                guard request.schemaVersion==1,request.targetKind==target.kind.rawValue,request.day==target.day,
                      request.timezone==target.timezone,request.actionCount>0,request.actionCount<=5000,
                      target.kind != .activity || request.targetID==target.activityID,
                      CanonicalGrounding.unexpired(request.expiresAt,now:Date()) else {throw WriterFailure.invalidInput}
                var actions=request.actions,next=request.next
                guard actions.count<=request.actionCount else {throw WriterFailure.invalidInput}
                while let offset=next {
                    try Task.checkCancellation()
                    guard offset==actions.count,offset<request.actionCount else {throw WriterFailure.invalidInput}
                    let page=try await core.page(request.id,offset)
                    guard page.actionCount==request.actionCount,!page.actions.isEmpty,page.actions.count<=100 else {throw WriterFailure.invalidInput}
                    actions+=page.actions;next=page.next
                    guard actions.count<=request.actionCount else {throw WriterFailure.invalidInput}
                }
                try Task.checkCancellation()
                guard actions.count==request.actionCount,Set(actions.map(\.id)).count==actions.count,
                      CanonicalGrounding.unexpired(request.expiresAt,now:Date()),
                      await core.permitted(request,actions) else {throw WriterFailure.denied}
                func fallback(_ reason:PendingWriterNote.Reason) -> CoreWriterResult {
                    .pending(PendingWriterNote(requestID:request.id,reason:reason,actionIDs:actions.map(\.id),fallback:actions.map {
                        GroundedBullet(text:$0.description,actionIDs:[$0.id],assertion:CanonicalGrounding.assertion($0.state))
                    }))
                }
                // One call covers the whole moment or day. claude/ready-1002 (owner): a moment over 400 actions, or
                // whose ITEMS view would not fit, is written in segments (`CanonicalGrounding.chunks`) and merged; a day
                // like that, or a moment over `maxChunkedActions`, stays pending with every action ID, never truncated.
                let chunks:[NoteChunk]?
                do {chunks=try CanonicalGrounding.chunks(request,actions:actions,appNames:appNames,localIntentSessions:localIntentSessions)} catch {return fallback(.capacity)}
                let view=chunks==nil ? try? ModelView(request:request,actions:actions,appNames:appNames,localIntentSessions:localIntentSessions) : nil
                guard chunks != nil || view != nil else {return fallback(.capacity)}
                let output:CanonicalNoteOutput
                sent=true
                do {output=try await generate(request,actions)} catch {
                    try Task.checkCancellation()
                    if error is CancellationError {throw error}
                    if case WriterFailure.requestExpired=error {
                        try await core.cancel(request.id)
                        throw error
                    }
                    guard await core.permitted(request,actions),CanonicalGrounding.unexpired(request.expiresAt,now:Date()) else {throw WriterFailure.denied}
                    switch error {
                    case WriterFailure.capacity:return fallback(.capacity)
                    case WriterFailure.notSent:return fallback(.notSent)
                    case CloudFailure.key:return fallback(.cloudKey)
                    case CloudFailure.credits:return fallback(.cloudCredits)
                    case CloudFailure.host:return fallback(.cloudHost)
                    case CloudFailure.offline:return fallback(.cloudOffline)
                    // Greedy decoding would replay the same answer: pending, never an automatic retry.
                    case WriterFailure.invalidOutput,is WriterRejection:return fallback(.invalidOutput)
                    default:return fallback(.providerUnavailable)
                    }
                }
                try Task.checkCancellation()
                guard output.requestID==request.id,await core.permitted(request,actions),
                      CanonicalGrounding.unexpired(request.expiresAt,now:Date()) else {throw WriterFailure.denied}
                // Provider-specific execution is not permission to bypass grounding.
                if let chunks {
                    guard let checked=try? CanonicalGrounding.checkChunked(output,request:request,chunks:chunks),checked==output else {return fallback(.invalidOutput)}
                } else {
                    guard let view,let checked=try? CanonicalGrounding.check(output,request:request,view:view),checked==output else {return fallback(.invalidOutput)}
                }
                var final=output
                let receipt:WriterCommitReceipt
                do {receipt=try await core.commit(output)}
                catch where CoreWriterAdapter.claimRefusal(error) {
                    try Task.checkCancellation()
                    guard await core.permitted(request,actions) else {throw WriterFailure.denied}
                    return fallback(.invalidOutput)
                }
                catch where CoreWriterAdapter.copyRefusal(error) {
                    // N7 (summaries/v3): core's copy guard sees every typed row and its whole run. Replace the bullets about
                    // typing with code-written lines and commit once more: one model run, never a scheduler retry. The
                    // "Keychain is locked" refusal is not a copy refusal and still retries.
                    try Task.checkCancellation()
                    // A note written in segments has no one view to salvage against: it stays pending (final locally).
                    guard let view else {return fallback(.invalidOutput)}
                    guard let salvaged=CanonicalGrounding.salvageCopied(output,request:request,view:view),
                          await core.permitted(request,actions),CanonicalGrounding.unexpired(request.expiresAt,now:Date()) else {throw error}
                    final=salvaged
                    do {receipt=try await core.commit(salvaged)}
                    catch where CoreWriterAdapter.claimRefusal(error) {return fallback(.invalidOutput)}
                }
                guard receipt.id==request.targetID,receipt.inputRevision==request.inputRevision,receipt.output==final else {throw WriterFailure.invalidOutput}
                return CoreWriterResult.committed(receipt)
            } catch {
                if Task.isCancelled {try? await core.cancel(request.id)}
                throw error
            }
          } catch {
            if !sent,!Task.isCancelled,!(error is CancellationError) {throw WriterFailure.notSent}
            throw error
          }
        }
        return try await withTaskCancellationHandler(operation:{try await work.value},onCancel:{work.cancel()})
    }
}
