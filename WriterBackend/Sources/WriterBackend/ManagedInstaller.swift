import Foundation
import CryptoKit

public struct PinnedAsset: Sendable {
    public let url: URL
    public let bytes: Int64
    public let sha256: String
    public init(url: URL, bytes: Int64, sha256: String) { self.url=url;self.bytes=bytes;self.sha256=sha256 }
}
public struct ModelInstallPlan: Sendable {
    public let asset: PinnedAsset
    public let minimumMemory: UInt64
    public let architecture: String
    public let runtimeCompatible: Bool
    public init(asset: PinnedAsset, minimumMemory: UInt64, architecture: String, runtimeCompatible: Bool) { self.asset=asset;self.minimumMemory=minimumMemory;self.architecture=architecture;self.runtimeCompatible=runtimeCompatible }
}
public enum InstallState: Sendable, Equatable { case idle, downloading(Int64, Int64), ready, cancelled, failed }
public typealias AssetChunks = @Sendable (URL) async throws -> AsyncThrowingStream<Data, Error>
/// Caller starts only after the explicit one-click install action. No launch-time
/// downloading. Each attempt uses its own file and never overwrites an installed model.
public actor ManagedInstaller {
    public private(set) var state: InstallState = .idle
    private var cancelled=false
    private var running=false
    private var attempt: Task<URL, Error>?
    public init() {}
    public func cancel() { cancelled=true;attempt?.cancel() }
    /// UI owns this awaited operation; cancel() interrupts a cooperative transfer.
    /// An explicit retry starts a fresh verified attempt, never appends unknown bytes.
    public func start(_ plan: ModelInstallPlan, directory: URL, physicalMemory: UInt64, freeBytes: Int64, architecture: String, chunks: @escaping AssetChunks, progress: @escaping @Sendable (InstallState) -> Void) async throws -> URL {
        guard attempt == nil else { throw WriterFailure.busy }
        let task=Task { try await self.install(plan,directory:directory,physicalMemory:physicalMemory,freeBytes:freeBytes,architecture:architecture,chunks:chunks,progress:progress) }
        attempt=task;defer {attempt=nil}
        return try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
    }
    public func install(_ plan: ModelInstallPlan, directory: URL, physicalMemory: UInt64, freeBytes: Int64, architecture: String, chunks: AssetChunks, progress: @Sendable (InstallState) -> Void) async throws -> URL {
        guard !running else { throw WriterFailure.busy }
        guard plan.runtimeCompatible, architecture == plan.architecture else { throw WriterFailure.incompatible }
        guard plan.asset.bytes > 0, plan.asset.bytes < Int64.max / 2,
              physicalMemory >= plan.minimumMemory, freeBytes >= plan.asset.bytes * 2 else { throw WriterFailure.capacity }
        guard plan.asset.sha256.count == 64, plan.asset.sha256.allSatisfy({$0.isHexDigit}), plan.asset.url.scheme == "https" else { throw WriterFailure.integrity }
        running=true;cancelled=false;defer { running=false }
        let fm=FileManager.default
        // Host supplies its private model directory. Symlinks are not followed.
        let values=try directory.resourceValues(forKeys:[.isDirectoryKey,.isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw WriterFailure.denied }
        let temp=directory.appendingPathComponent(UUID().uuidString+".partial")
        let final=directory.appendingPathComponent(plan.asset.sha256+".model")
        guard !fm.fileExists(atPath:final.path), fm.createFile(atPath:temp.path,contents:nil,attributes:[.posixPermissions:0o600]) else { throw WriterFailure.busy }
        defer { if fm.fileExists(atPath:temp.path) { try? fm.removeItem(at:temp) } }
        let handle=try FileHandle(forWritingTo:temp);defer { try? handle.close() }
        do {
            var digest=SHA256(), received:Int64=0
            state = .downloading(0,plan.asset.bytes);progress(state)
            for try await chunk in try await chunks(plan.asset.url) {
                try Task.checkCancellation();if cancelled { throw CancellationError() }
                guard chunk.count <= 1048576, Int64(chunk.count) <= plan.asset.bytes-received else { throw WriterFailure.integrity }
                try handle.write(contentsOf:chunk);digest.update(data:chunk);received += Int64(chunk.count)
                state = .downloading(received,plan.asset.bytes);progress(state)
            }
            try Task.checkCancellation();if cancelled { throw CancellationError() }
            let actual=digest.finalize().map { String(format:"%02x",$0) }.joined()
            guard received == plan.asset.bytes, actual == plan.asset.sha256.lowercased() else { throw WriterFailure.integrity }
            try handle.synchronize();try handle.close();try fm.moveItem(at:temp,to:final)
            state = .ready;progress(state);return final
        } catch {
            state = (cancelled || error is CancellationError) ? .cancelled : .failed
            progress(state);throw error
        }
    }
}
public enum WriterCandidates {
    // Original upstream provenance plus independently pinned, runtime-compatible
    // Unsloth GGUF recommendation. Install requires explicit user action.
    public static let qwenRevision="851bf6e806efd8d0a36b00ddf55e13ccb7b8cd0a"
    public static let qwenWeightHashes=["26a93f066e1916adb13453dae5a0c707c0fbc71299ed98779571a907b8e74c61","cb544bd9bfae93dc59b0f22b292f5933573854a7f9b97835c67060d7d910e188"]
    public static let qwenWeightBytes:Int64=9_319_828_096
    public static let llamaARM64=PinnedAsset(url:URL(string:"https://github.com/ggml-org/llama.cpp/releases/download/b9723/llama-b9723-bin-macos-arm64.tar.gz")!,bytes:10_943_910,sha256:"2cd552419b84b7b16598b95e9dd14572c86ecc13c96789cf06b7025d2dca815f")
    public static let ggufRevision="720bb031aae5488eae5d6a78768e6d826662b2ae"
    public static let llamaCommit="b14e3fb90ca8c760f4254ddc9aa7845ebbdb2edf"
    public static let recommended: ModelInstallPlan? = ModelInstallPlan(asset: PinnedAsset(url: URL(string:"https://huggingface.co/unsloth/Qwen3.5-4B-GGUF/resolve/720bb031aae5488eae5d6a78768e6d826662b2ae/Qwen3.5-4B-Q4_K_M.gguf")!,bytes:2_740_937_888,sha256:"00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4"),minimumMemory:8_589_934_592,architecture:"arm64",runtimeCompatible:true)
}
