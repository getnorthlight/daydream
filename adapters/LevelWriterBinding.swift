import Foundation
import MemoryCore
import WriterBackend

/// Writes the levels above moments (blocks, days, weeks, months) one note at a time. The model gets one try and one
/// repair turn; after that, or with no model (cloud mode in test 6: levels cost no cloud calls), code writes the note
/// from the children's own lines. Core checks every note again before it is saved.
public actor LevelWriterBinding {
    public typealias Generate = @Sendable (_ instruction:String,_ evidence:String,_ maxTokens:Int,_ prefill:String) async throws -> String
    public struct Step: Sendable {
        public let note:LevelNote
        /// "model", "repair" (the second answer passed), "extractive" (code after two refusals, or no model), "code"
        /// (a one-moment block: nothing to group) or "plain" (code's note with no window-title names: its own would
        /// repeat a typed draft).
        public let source:String
        public let rejections:[String]
        public let answers:[String]
    }
    public typealias Load = @Sendable () async throws -> Void
    public typealias Unload = @Sendable () async -> Void
    private let store:MemoryStore
    private let generate:Generate?
    private let load:Load?, unload:Unload?
    /// The generator a model-written note is saved with ("local/qwen3.5-4b-q4_k_m", or the cloud model).
    private let generator:String
    /// fix/sx-engine-battery: whether the model may read this request (cloud: only periods that start after cloud was
    /// first turned on). false: code writes the note from the children's own lines, as with no model.
    public typealias Permits = @Sendable (LevelRequest) async -> Bool
    private let permits:Permits?
    /// `load` runs before the first answer and `unload` after the last, like the moment writer: the local runtime is
    /// shared with it and is loaded only while a note is being written. With a `BatchRuntime` both are cheap inside a
    /// batch (fix/sx-engine-battery: one load per batch).
    public init(store:MemoryStore,generate:Generate?,load:Load?=nil,unload:Unload?=nil,generator:String="local/qwen3.5-4b-q4_k_m",permits:Permits?=nil) {
        self.store=store; self.generate=generate; self.load=load; self.unload=unload; self.generator=generator; self.permits=permits
    }
    public static func local(store:MemoryStore,runtime:any LocalInference) -> LevelWriterBinding {
        LevelWriterBinding(store:store,
            generate:{ i,e,m,p in String(decoding:try await runtime.generate(instruction:i,evidence:e,maxTokens:m,prefill:p),as:UTF8.self) },
            load:{ try await runtime.load() }, unload:{ await runtime.unload() })
    }
    /// fix/sx-engine-battery: level notes written by the cloud writer, through the same consent, key and checks as a
    /// moment note (`complete`, CloudWriter.completeText with LevelGrounding's instruction and evidence). The cloud
    /// answers with the whole JSON object, so the local prefill is not sent. `permits` false, or a model that keeps
    /// failing (LevelRunner), and code writes the note.
    public static func cloud(store:MemoryStore,model:String,permits:@escaping Permits,
                             complete:@escaping @Sendable (_ instruction:String,_ evidence:String,_ maxTokens:Int) async throws -> String) -> LevelWriterBinding {
        LevelWriterBinding(store:store,generate:{ i,e,m,_ in try await complete(i,e,m) },generator:"cloud/"+model,permits:permits)
    }
    /// Requests core refused to save (by `MemoryStore.workKey`), and when: passed over for `retryAfter`, so one note
    /// that can't be saved (a locked Keychain, a note that repeats a typed draft) never holds every later block, day,
    /// week and month (r1 levels-pipeline). A changed input is a new key, tried at once.
    private var refused=[String:Date]()
    public static let retryAfter:TimeInterval=3600
    /// The model (its load or an answer) failed, so nothing was saved. `LevelRunner` backs off on this error only; a
    /// store error or a cancel is passed on as it is.
    public struct ModelFailure: Error { public let underlying:Error }
    /// Written with the model on this Mac (local mode), or by code only (cloud mode).
    public nonisolated var usesModel:Bool { generate != nil }
    /// The next level note, or nil when nothing waits. `codeOnly`: code writes it from the children's own lines, as in
    /// cloud mode, and the model isn't loaded (fix/r1-writer: while the model keeps failing).
    /// `momentWillBeWritten` (fix/sx-engine-battery): false for a moment that will never get a model note (idle-only, empty,
    /// or set aside after its note failed for good), so a block need not wait for it.
    public func step(timezone:String,now:Date=Date(),backfillDays:Int=7,codeOnly:Bool=false,momentWillBeWritten:@escaping @Sendable (String) -> Bool = {_ in true}) async throws -> Step? {
        refused=refused.filter { now.timeIntervalSince($0.value) < Self.retryAfter }
        // fix/r1-writer: background store work that can simply run again lets the main thread in (StoreWait.swift), as the
        // summary queue, the timeline and the Forget preview do (gold r3-store).
        let skipping=Set(refused.keys)
        guard let request=try StoreWait.lettingMainIn({ try store.writerLevelWork(timezone:timezone,now:now,backfillDays:backfillDays,skipping:skipping,momentWillBeWritten:momentWillBeWritten) }).first else { return nil }
        do { return try await write(request,now:now,codeOnly:codeOnly,momentWillBeWritten:momentWillBeWritten) }
        catch let error as MemError { refused[MemoryStore.workKey(request)]=now; throw error }
    }
    public func write(_ request:LevelRequest,now:Date=Date(),codeOnly:Bool=false,momentWillBeWritten:@escaping @Sendable (String) -> Bool = {_ in true}) async throws -> Step {
        var rejections=[String](), answers=[String]()
        let allowed=await permits?(request) ?? true
        if !request.codeOnly, !codeOnly, allowed, let generate {
            let written:Step?
            do {
                do { try await load?() } catch is CancellationError {throw CancellationError()} catch { throw ModelFailure(underlying:error) }
                written=try await attempts(request,generate:generate,now:now,rejections:&rejections,answers:&answers,momentWillBeWritten:momentWillBeWritten)
            } catch { await unload?(); throw Task.isCancelled ? CancellationError() : error }
            await unload?()
            if let written { return written }
        }
        // fix/r1-writer: a writer turned off while this note was being written saves nothing.
        try Task.checkCancellation()
        let (title,lines)=LevelGrounding.extractive(request)
        do {
            let note=try StoreWait.lettingMainIn { try store.commitLevel(request,title:title,lines:lines,generator:LevelWriterVersion.extractive,now:now,momentWillBeWritten:momentWillBeWritten) }
            return Step(note:note,source:request.codeOnly ? "code" : "extractive",rejections:rejections,answers:answers)
        } catch MemError.invalid(let message) where message == MemoryStore.typedCopyRefusal && LevelGrounding.threaded(request) {
            // The code's note repeats a short typed draft (a chat named after the question typed into it): the same note
            // with no window-title names ("AI chat") instead of none at all.
            rejections.append("core: "+message)
            let plain=LevelGrounding.plainThreadNote(request)
            let note=try StoreWait.lettingMainIn { try store.commitLevel(request,title:plain.title,lines:plain.lines,generator:LevelWriterVersion.extractive,now:now,momentWillBeWritten:momentWillBeWritten) }
            return Step(note:note,source:"plain",rejections:rejections,answers:answers)
        }
    }
    // MARK: day review clauses (claude/day-review-1003)

    public struct ClauseStep: Sendable {
        public let clause:DayReviewClause
        /// "model" or "repair".
        public let source:String
        public let rejections:[String]
    }
    /// Clause requests (key|signature) the model couldn't write or core refused, and when: passed over for `retryAfter`.
    private var refusedClauses=[String:Date]()
    /// The next day-review clause due (`MemoryStore.reviewClauseWork`), written by the model: one answer and one repair
    /// turn, checked (`DayReviewClauses.validate`), then saved by core. nil when none is due, with no model (code's own
    /// bullets need no clause), when the cloud may not read it, or when both answers were refused (the card keeps its code
    /// bullets: a clause is never required). A model that fails throws `ModelFailure`.
    public func reviewClause(timezone:String,now:Date=Date()) async throws -> ClauseStep? {
        guard let generate else { return nil }
        refusedClauses=refusedClauses.filter { now.timeIntervalSince($0.value) < Self.retryAfter }
        let skipping=Set(refusedClauses.keys)
        let work=try StoreWait.lettingMainIn { try store.reviewClauseWork(timezone:timezone,now:now,skipping:skipping,limit:4) }
        var request:DayReviewClauseRequest?
        for r in work {
            if await permits?(r.levelRequest) ?? true { request=r; break }
            refusedClauses[r.key+"|"+r.signature]=now
        }
        guard let request else { return nil }
        let key=request.key+"|"+request.signature
        var rejections=[String]()
        // The runtime is loaded for this clause only, as for a level note (cheap inside a batch).
        let written:ClauseStep?
        do {
            do { try await load?() } catch is CancellationError {throw CancellationError()} catch { throw ModelFailure(underlying:error) }
            written=try await clauseAttempts(request,generate:generate,now:now,rejections:&rejections)
        } catch {
            await unload?()
            if error is MemError { refusedClauses[key]=now }
            throw Task.isCancelled ? CancellationError() : error
        }
        await unload?()
        if written == nil { refusedClauses[key]=now }
        return written
    }
    private func clauseAttempts(_ request:DayReviewClauseRequest,generate:Generate,now:Date,rejections:inout [String]) async throws -> ClauseStep? {
        // claude/dayeval-1005: the writer on this Mac also reads the thread's typed prompts and document words; a cloud writer
        // never does (its generator is "cloud/…"). The words live in this request only while it is written.
        var request=request
        if generator.hasPrefix("local/") {
            let typed=try StoreWait.lettingMainIn { try store.reviewTypedFacts(request,writer:.local,now:now) }
            if !typed.isEmpty { request.notes+=typed }
        }
        var evidence=DayReviewClauses.activeEvidence(request)
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let raw:String
            do { raw=try await generate(DayReviewClauses.activeInstruction,evidence,DayReviewClauses.maxTokens,DayReviewClauses.prefill) }
            catch is CancellationError {throw CancellationError()} catch { throw ModelFailure(underlying:error) }
            // An answer that arrives after the writer was turned off is never saved.
            try Task.checkCancellation()
            do {
                let text=try DayReviewClauses.activeValidate(raw,request:request)
                let clause=try StoreWait.lettingMainIn { try store.commitReviewClause(request,text:text,generator:DayReviewClauses.activeVersion,now:now) }
                return ClauseStep(clause:clause,source:attempt == 0 ? "model" : "repair",rejections:rejections)
            } catch let reject as DayReviewClauses.Reject {
                rejections.append("clause: "+reject.reason)
                evidence=DayReviewClauses.activeRepair(request,previous:raw,problem:reject.reason)
            } catch MemError.invalid(let message) where message.contains("copy") || message.contains("typed") {
                rejections.append("core: "+message)
                evidence=DayReviewClauses.activeRepair(request,previous:raw,problem:"Say it in your own words.")
            }
        }
        return nil
    }

    /// One answer and one repair turn; nil when both were refused.
    private func attempts(_ request:LevelRequest,generate:Generate,now:Date,rejections:inout [String],answers:inout [String],momentWillBeWritten:@escaping @Sendable (String) -> Bool) async throws -> Step? {
        let instruction=LevelGrounding.instruction(for:request), prefill=LevelGrounding.prefill(request.level)
        var evidence=LevelGrounding.evidence(request)
        for attempt in 0..<2 {
            try Task.checkCancellation()
            let raw:String
            do { raw=try await generate(instruction,evidence,request.level.maxTokens,prefill) } catch is CancellationError {throw CancellationError()} catch { throw ModelFailure(underlying:error) }
            answers.append(raw)
            // An answer that arrives after the writer was turned off is never saved (fix/r1-writer).
            try Task.checkCancellation()
            do {
                let (title,lines)=try LevelGrounding.validate(raw,request:request)
                let note=try StoreWait.lettingMainIn { try store.commitLevel(request,title:title,lines:lines,generator:generator,now:now,momentWillBeWritten:momentWillBeWritten) }
                return Step(note:note,source:attempt == 0 ? "model" : "repair",rejections:rejections,answers:answers)
            } catch let reject as LevelGrounding.Reject {
                rejections.append(reject.code+": "+reject.reason)
                evidence=LevelGrounding.repair(request,previous:raw,problem:reject.reason)
            } catch MemError.invalid(let message) where message.hasPrefix("Level note refused") || message.contains("copy") || message.contains("typed") {
                rejections.append("core: "+message)
                evidence=LevelGrounding.repair(request,previous:raw,problem:"Say it in your own words and keep only what the notes say.")
            }
        }
        return nil
    }
}

extension MemoryStore {
    /// The next level request for the writer. `momentWillBeWritten` (fix/notes-quality's `levelWork`/`blockPlan` hook,
    /// wired here at fix/sx-all): a block never waits on a moment the writer will not write (in Low Power Mode, for example).
    func writerLevelWork(timezone:String,now:Date,backfillDays:Int,skipping:Set<String>,momentWillBeWritten:@escaping @Sendable (String) -> Bool) throws -> [LevelRequest] {
        try levelWork(timezone:timezone,now:now,backfillDays:backfillDays,limit:1,skipping:skipping,momentWillBeWritten:momentWillBeWritten)
    }
}

/// fix/r1-writer: the app's level notes, one at a time, as a task its writer can stop. `stop` cancels the note being
/// written and waits until it has finished (the runtime unloaded, nothing saved after the cancel), so summaries turned
/// off write no more level notes, and summaries turned on again right away never load a second copy of the model while
/// the first is still loading: a step asked for while one is still running (or still finishing) does nothing.
///
/// When the model fails (it doesn't load, or doesn't answer), it is tried again after 1, 5, 15, then every 60 minutes,
/// not every minute (each load of a signed build checks the whole model file again). From the third failure in a row,
/// code writes the level notes meanwhile, as in cloud mode, so the summaries still appear. A note the model writes, or
/// a settings change (`reset`), starts over.
public actor LevelRunner {
    public static let backoff:[TimeInterval]=[60,300,900,3600]
    public static let fallbackAfter=3
    private var running:Task<LevelWriterBinding.Step?,Error>?
    private var failures=0
    private var retryAt=Date.distantPast
    public init() {}
    /// Model failures in a row since the last note it wrote, and when it is tried again.
    public var modelFailures:Int { failures }
    public var modelRetryAt:Date { retryAt }
    /// Settings changed (a writer turned on, the privacy settings): the model is tried again at once.
    public func reset() { failures=0; retryAt = .distantPast }
    /// A level note is being written, or a stopped one is still finishing.
    public var busy:Bool { running != nil }
    /// `codeOnly` (fix/sx-engine-battery: while the model waits for power) writes the next note by code and never loads the model.
    public func step(_ binding:LevelWriterBinding,timezone:String,now:Date=Date(),codeOnly forced:Bool=false,
                     momentWillBeWritten:@escaping @Sendable (String) -> Bool = {_ in true}) async throws -> LevelWriterBinding.Step? {
        guard running == nil else { return nil }
        var codeOnly=forced
        if !forced, binding.usesModel, failures > 0, now < retryAt {
            guard failures >= Self.fallbackAfter else { return nil }
            codeOnly=true
        }
        let task=Task { try await binding.step(timezone:timezone,now:now,codeOnly:codeOnly,momentWillBeWritten:momentWillBeWritten) }
        running=task
        defer { if running == task { running=nil } }
        do {
            let step=try await withTaskCancellationHandler(operation:{ try await task.value },onCancel:{ task.cancel() })
            // The model loaded and answered (a refused answer too): start over.
            if let step, !codeOnly, binding.usesModel, step.source != "code" { reset() }
            return step
        } catch let failure as LevelWriterBinding.ModelFailure {
            failures += 1
            retryAt=now.addingTimeInterval(Self.backoff[min(failures,Self.backoff.count)-1])
            throw failure
        }
    }
    /// claude/day-review-1003: the next day-review clause, as a task `stop` cancels, sharing the level notes' one-at-a-time
    /// rule and the model's back-off. Nothing while the model waits out a failure (the card keeps its code bullets).
    public func clause(_ binding:LevelWriterBinding,timezone:String,now:Date=Date()) async throws -> LevelWriterBinding.ClauseStep? {
        guard running == nil, binding.usesModel, failures == 0 || now >= retryAt else { return nil }
        let task=Task<LevelWriterBinding.ClauseStep?,Error> { try await binding.reviewClause(timezone:timezone,now:now) }
        // `running` holds a task `stop` can cancel and wait for; cancelling it cancels the clause.
        let holder=Task<LevelWriterBinding.Step?,Error> {
            try await withTaskCancellationHandler(operation:{ _ = try await task.value; return nil },onCancel:{ task.cancel() })
        }
        running=holder
        defer { if running == holder { running=nil } }
        do {
            let step=try await withTaskCancellationHandler(operation:{ try await task.value },onCancel:{ task.cancel(); holder.cancel() })
            if step != nil { reset() }
            return step
        } catch let failure as LevelWriterBinding.ModelFailure {
            failures += 1
            retryAt=now.addingTimeInterval(Self.backoff[min(failures,Self.backoff.count)-1])
            throw failure
        }
    }
    /// Cancels the note being written and waits for it to finish.
    public func stop() async {
        guard let task=running else { return }
        task.cancel()
        _ = await task.result
        if running == task { running=nil }
    }
}
