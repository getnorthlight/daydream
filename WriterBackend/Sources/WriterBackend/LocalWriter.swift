import Foundation

/// In-process runtime adapter. No tools, shell, user ports or daemon contract.
/// Cancellation MUST interrupt inference; unload releases model/KV resources.
public protocol LocalInference: Sendable {
    func load() async throws
    func generate(instruction: String, evidence: String, maxTokens: Int) async throws -> Data
    /// The assistant turn starts with `prefill` and the result is what the model wrote after it.
    /// A runtime that cannot prefill returns a whole answer (CanonicalGrounding.withPrefill accepts both).
    func generate(instruction: String, evidence: String, maxTokens: Int, prefill: String) async throws -> Data
    /// Immutable prepared-request deadline; no expiry extension or task-wide cancellation.
    func generate(instruction: String, evidence: String, maxTokens: Int, prefill: String, expiresAt: Date) async throws -> Data
    func unload() async
}
extension LocalInference {
    public func generate(instruction: String, evidence: String, maxTokens: Int, prefill: String, expiresAt: Date) async throws -> Data {
        try Task.checkCancellation()
        guard Date() < expiresAt else { throw WriterFailure.requestExpired }
        let result = try await generate(instruction: instruction, evidence: evidence, maxTokens: maxTokens, prefill: prefill)
        try Task.checkCancellation()
        guard Date() < expiresAt else { throw WriterFailure.requestExpired }
        return result
    }
    public func generate(instruction: String, evidence: String, maxTokens: Int, prefill: String) async throws -> Data {
        try await generate(instruction: instruction, evidence: evidence, maxTokens: maxTokens)
    }
}
public actor LocalWriter: NoteWriter {
    private let runtime: any LocalInference
    private let policy: PolicyCheck
    private var busy=false
    public init(runtime: any LocalInference, policy: @escaping PolicyCheck) { self.runtime=runtime;self.policy=policy }
    public func write(_ batch: WriterBatch) async throws -> WriterNote {
        guard !busy else { throw WriterFailure.busy };busy=true
        defer { busy=false }
        guard await policy(batch) else { throw WriterFailure.denied }
        do {
            try Task.checkCancellation();try await runtime.load()
            let data=try await runtime.generate(instruction:Grounding.instruction,evidence:Grounding.prompt(batch),maxTokens:8192)
            await runtime.unload()
            try Task.checkCancellation()
            guard data.count <= 131072, await policy(batch) else { throw WriterFailure.denied }
            return try Grounding.validate(JSONDecoder().decode(ModelNote.self,from:data),batch:batch,provider:"qwen3.5-4b/candidate",zdr:false)
        } catch { await runtime.unload();throw WriterFailure.unavailable }
    }
}
/// Core retains pending batches durably and schedules retries explicitly.
/// This worker never writes canonical state, scans history or calls another provider.
public actor SettledWriter {
    private let writer: any NoteWriter
    private let policy: PolicyCheck
    private var running=false
    public init(writer: any NoteWriter, policy: @escaping PolicyCheck) { self.writer=writer;self.policy=policy }
    public func process(_ batch: WriterBatch, lastActivity: Date, now: Date = Date()) async throws -> WriterNote {
        guard !running, now.timeIntervalSince(lastActivity) >= 2 else { throw WriterFailure.busy }
        guard await policy(batch) else { throw WriterFailure.denied }
        running=true;defer { running=false }
        let worker=Task.detached(priority:.background) { try await self.writer.write(batch) }
        do {
            let note=try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
            guard await policy(batch) else { throw WriterFailure.denied }
            return note
        } catch {
            try Task.checkCancellation()
            guard await policy(batch) else { throw WriterFailure.denied }
            return Grounding.fallback(batch)
        }
    }
}
