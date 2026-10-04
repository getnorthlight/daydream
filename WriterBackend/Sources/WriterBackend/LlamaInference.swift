import Foundation
import CryptoKit
import CLlamaBridge

private final class InferencePausePredicate: @unchecked Sendable {
    let shouldPause: @Sendable () -> Bool
    init(_ shouldPause: @escaping @Sendable () -> Bool) { self.shouldPause = shouldPause }
    static let callback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { data in
        guard let data else { return 0 }
        return Unmanaged<InferencePausePredicate>.fromOpaque(data).takeUnretainedValue().shouldPause() ? 1 : 0
    }
}

private final class InferenceExpiry: @unchecked Sendable {
    let expiresAt: Date
    init(_ expiresAt: Date) { self.expiresAt=expiresAt }
    static let callback: @convention(c) (UnsafeMutableRawPointer?) -> Int32 = { data in
        guard let data else { return 1 }
        return Date() >= Unmanaged<InferenceExpiry>.fromOpaque(data).takeUnretainedValue().expiresAt ? 1 : 0
    }
}

/// Serial in-process CPU/Metal execution on a background queue. No shell/server.
public final class LlamaInference: LocalInference, @unchecked Sendable {
    private let queue=DispatchQueue(label:"MacMem.Writer.Inference",qos:.background)
    private let runtime:OpaquePointer
    private let library:URL,model:URL
    private let signedDistributionID: String?
    private let revocationResponses: [Data]
    private let pausePredicate: InferencePausePredicate
    /// Construct only from the installer/offline verifier's pinned assets.
    /// shouldPause must be a quick thread-safe read; it is called only on the
    /// inference queue. It parks the same generation without cancelling it.
    public init(files:CompatibleWriterFiles, shouldPause: @escaping @Sendable () -> Bool = { false }) {self.library=files.library;self.model=files.model;self.signedDistributionID=files.signedDistributionID;self.revocationResponses=files.revocationResponses;self.pausePredicate=InferencePausePredicate(shouldPause);runtime=wr_create()!}
    deinit {wr_destroy(runtime)}
    public func load() async throws {
        let attempt = LoadAttempt()
        if Task.isCancelled { attempt.cancel() }
        try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Void,Error>) in
                queue.async {
                    defer { attempt.preflight = nil }
                    do {
                        try attempt.check()
                        if let id = self.signedDistributionID {
                            guard let plan = WriterCandidates.recommended else { throw WriterFailure.incompatible }
                            // fix/sx-engine-battery: the model was hashed when summaries were turned on (the offline restore).
                            // Each load reads its metadata only (one lstat); it is hashed again only if the file changed.
                            try ModelIdentity.verify(self.model, bytes: plan.asset.bytes, hash: plan.asset.sha256, checkCancellation: attempt.check)
                            attempt.preflight = {
                                let checked = try SignedRuntimeLoader.validate(model: self.model, distributionID: id, revocationResponses: self.revocationResponses, checkModel: false, checkCancellation: attempt.check)
                                guard checked.library == self.library else { throw WriterFailure.integrity }
                            }
                        }
                        let status=wr_load_attempt(self.runtime,self.library.path,self.model.path,attempt.ticket,LoadAttempt.callback,Unmanaged.passUnretained(attempt).toOpaque())
                        try attempt.check()
                        if let failure = attempt.failure { throw failure }
                        if status==0 {continuation.resume()} else {continuation.resume(throwing:WriterFailure.unavailable)}
                    } catch { continuation.resume(throwing: error) }
                }
            }
        },onCancel:{attempt.cancel()})
        try Task.checkCancellation()
    }
    public func generate(instruction:String,evidence:String,maxTokens:Int) async throws -> Data {
        try await generate(instruction:instruction,evidence:evidence,maxTokens:maxTokens,prefill:"")
    }
    public func generate(instruction:String,evidence:String,maxTokens:Int,prefill:String) async throws -> Data {
        try await generate(instruction:instruction,evidence:evidence,maxTokens:maxTokens,prefill:prefill,expiry:nil)
    }
    public func generate(instruction:String,evidence:String,maxTokens:Int,prefill:String,expiresAt:Date) async throws -> Data {
        try await generate(instruction:instruction,evidence:evidence,maxTokens:maxTokens,prefill:prefill,expiry:InferenceExpiry(expiresAt))
    }
    private func generate(instruction:String,evidence:String,maxTokens:Int,prefill:String,expiry:InferenceExpiry?) async throws -> Data {
        try Task.checkCancellation()
        let prompt=try QwenNoThinkingTemplate.render(instruction:instruction,evidence:evidence,prefill:prefill)
        do {
        let data = try await withTaskCancellationHandler(operation:{
            try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<Data,Error>) in
                queue.async {
                    var output:UnsafeMutablePointer<CChar>?
                    wr_set_pause_callback(self.runtime,InferencePausePredicate.callback,Unmanaged.passUnretained(self.pausePredicate).toOpaque())
                    defer { wr_set_pause_callback(self.runtime,nil,nil) }
                    let status: Int32
                    if let expiry {
                        status=wr_generate_until(self.runtime,prompt,Int32(min(1024,maxTokens)),&output,InferenceExpiry.callback,Unmanaged.passUnretained(expiry).toOpaque())
                    } else { status=wr_generate(self.runtime,prompt,Int32(min(1024,maxTokens)),&output) }
                    defer {wr_release(output)}
                    if status==0,let output {continuation.resume(returning:Data(String(cString:output).utf8))}
                    else if status==13 {continuation.resume(throwing:WriterFailure.requestExpired)}
                    else {continuation.resume(throwing:WriterFailure.unavailable)}
                }
            }
        },onCancel:{wr_cancel(self.runtime)})
        try Task.checkCancellation()
        return data
        } catch { try Task.checkCancellation();throw error }
    }
    public func offloadEvidence() async -> (layers:Int,total:Int) {
        await withCheckedContinuation { c in queue.async {c.resume(returning:(Int(wr_offloaded_layers(self.runtime)),Int(wr_total_layers(self.runtime))))} }
    }
    /// Value-free atomic diagnostic: 0 idle, 1 setup, 2 prefill decode,
    /// 3 generation, 4 paused at a safe generation boundary.
    public func executionPhase() -> Int {Int(wr_execution_phase(runtime))}
    /// Value-free diagnostic: last completed bridge status, -1 before generation.
    public func lastGenerationStatus() -> Int {Int(wr_generation_status(runtime))}
    public func dependenciesAreLocal() async -> Bool {
        await withCheckedContinuation { c in queue.async {c.resume(returning:wr_dependencies_local(self.runtime,self.library.deletingLastPathComponent().path)==1)} }
    }
    public func unload() async {await withCheckedContinuation { c in queue.async {wr_unload(self.runtime);c.resume()} }}
}
