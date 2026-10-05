import Foundation
import CryptoKit

public struct CompatibleWriterFiles: Sendable {
    public let model: URL
    public let library: URL
    let signedDistributionID: String?
    let revocationResponses: [Data]
    public let derivation: String
    init(model: URL, library: URL, signedDistributionID: String? = nil, revocationResponses: [Data] = [], derivation:String = "qwen3.5-4b-q4km-llama-b9723-v1") {
        self.derivation=derivation
        self.model = model; self.library = library; self.signedDistributionID = signedDistributionID; self.revocationResponses = revocationResponses
    }
}
public struct WriterCapacity: Sendable {
    public let memory: UInt64
    public let freeBytes: Int64
    public let architecture: String
    public static func read(at directory: URL) throws -> Self {
        let fs = try FileManager.default.attributesOfFileSystem(forPath: directory.path)
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "unsupported"
        #endif
        return Self(memory: ProcessInfo.processInfo.physicalMemory,
                    freeBytes: (fs[.systemFreeSize] as? NSNumber)?.int64Value ?? 0, architecture: arch)
    }
}

/// Explicit-install entry point only. No startup downloads, daemon, port or package manager.
/// Root must be an app-owned private directory. Cancellation leaves only previously verified
/// complete assets, reusable by an explicit retry. Never accepts paths from captured evidence.
public actor CompatibleInstallation {
    /// Verified LC_BUILD_VERSION on all seven pinned b9723 dylibs: minos 26.0.
    /// Module can compile on macOS 13; this particular binary cannot run there.
    public static func supportsRuntime(osMajor: Int, architecture: String) -> Bool {
        osMajor >= 26 && architecture == "arm64"
    }
    private static func requireSupportedHost() throws {
        #if arch(arm64)
        let architecture="arm64"
        #else
        let architecture="unsupported"
        #endif
        guard supportsRuntime(osMajor:ProcessInfo.processInfo.operatingSystemVersion.majorVersion,architecture:architecture) else {throw WriterFailure.incompatible}
    }
    private let downloader = ManagedInstaller()
    private var running = false
    private var cancelled = false
    private var diskWork: Task<URL, Error>?
    private var modelWork: Task<URL, Error>?
    public init() {}
    public func cancel() async { cancelled = true; diskWork?.cancel(); modelWork?.cancel(); await downloader.cancel() }

    public func install(in root: URL, chunks: @escaping AssetChunks = {try await AssetDownload.chunks(from:$0)},
                        modelChunks: @escaping ModelRangeChunks = {try await AssetDownload.chunks(from:$0,offset:$1)},
                        progress: @escaping @Sendable (InstallState) -> Void) async throws -> CompatibleWriterFiles {
        guard !running else { throw WriterFailure.busy }
        try Self.requireSupportedHost()
        try Self.privateDirectory(root)
        guard let modelPlan = WriterCandidates.recommended else { throw WriterFailure.incompatible }
        running = true; cancelled = false; defer { running = false }
        let capacity = try WriterCapacity.read(at: root)
        guard capacity.architecture == "arm64", capacity.memory >= modelPlan.minimumMemory else { throw WriterFailure.capacity }
        let modelTask = Task {
            try await PersistentModelCache.acquire(in: root,
                priorRoots: PersistentModelCache.searchRoots(for:root), chunks:modelChunks, progress: progress)
        }
        modelWork = modelTask
        defer {modelWork = nil}
        let model = try await withTaskCancellationHandler(operation: {try await modelTask.value}, onCancel: {modelTask.cancel()})
        try check()
        let runtimePlan = ModelInstallPlan(asset: WriterCandidates.llamaARM64, minimumMemory: modelPlan.minimumMemory, architecture: "arm64", runtimeCompatible: true)
        let archive = try await acquire(runtimePlan, root: root, chunks: chunks, progress: progress)
        try check()
        let library = try await performDiskWork { try Self.extractRuntime(archive: archive, root: root) }
        try check()
        progress(.ready)
        return CompatibleWriterFiles(model: model, library: library)
    }
    private func check() throws { try Task.checkCancellation(); if cancelled { throw CancellationError() } }
    private func performDiskWork(_ work: @escaping @Sendable () throws -> URL) async throws -> URL {
        let task=Task.detached(priority:.utility) {try work()}
        diskWork=task;defer {diskWork=nil}
        return try await withTaskCancellationHandler(operation:{try await task.value},onCancel:{task.cancel()})
    }
    private func acquire(_ plan: ModelInstallPlan, root: URL, chunks: @escaping AssetChunks,
                         progress: @escaping @Sendable (InstallState) -> Void) async throws -> URL {
        try check()
        let file = root.appendingPathComponent(plan.asset.sha256 + ".model")
        if FileManager.default.fileExists(atPath: file.path) {
            return try await performDiskWork {try Self.verify(file, asset: plan.asset);return file}
        }
        let capacity = try WriterCapacity.read(at: root)
        return try await downloader.start(plan, directory: root, physicalMemory: capacity.memory,
                                          freeBytes: capacity.freeBytes, architecture: capacity.architecture,
                                          chunks: chunks, progress: { state in if state != .ready { progress(state) } })
    }

    /// Revalidates offline files before use, including every dependency. Does not copy or download.
    public static func restore(in root:URL) async throws -> CompatibleWriterFiles {
        let worker=Task.detached(priority:.utility) {
            try requireSupportedHost();try privateDirectory(root)
            guard let plan=WriterCandidates.recommended else {throw WriterFailure.incompatible}
            return try validate(model:root.appendingPathComponent(plan.asset.sha256+".model"),runtimeDirectory:root.appendingPathComponent("llama-b9723-arm64"))
        }
        return try await withTaskCancellationHandler(operation:{try await worker.value},onCancel:{worker.cancel()})
    }
    public static func validate(model: URL, runtimeDirectory: URL) throws -> CompatibleWriterFiles {
        try requireSupportedHost()
        guard let plan = WriterCandidates.recommended else { throw WriterFailure.incompatible }
        guard ProcessInfo.processInfo.physicalMemory>=plan.minimumMemory else {throw WriterFailure.capacity}
        try privateDirectory(model.deletingLastPathComponent())
        try verify(model, asset: plan.asset)
        try privateDirectory(runtimeDirectory)
        for file in runtimeFiles { try verify(runtimeDirectory.appendingPathComponent(file.output), bytes: Int64(file.bytes), hash: file.hash) }
        return CompatibleWriterFiles(model: model, library: runtimeDirectory.appendingPathComponent("libllama.0.dylib"))
    }
    static func privateDirectory(_ url: URL) throws {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              WriterPaths.unlinked(url) else { throw WriterFailure.denied }
    }
    public static func verify(_ url: URL, asset: PinnedAsset) throws { try verify(url, bytes: asset.bytes, hash: asset.sha256) }
    static func verify(_ url: URL, bytes: Int64, hash: String, checkCancellation: () throws -> Void = {try Task.checkCancellation()}) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, Int64(values.fileSize ?? -1) == bytes else { throw WriterFailure.integrity }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try checkCancellation(); digest.update(data: data)
        }
        guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == hash else { throw WriterFailure.integrity }
    }

    /// The tar utility emits one fixed regular file to stdout. No archive path, symlink,
    /// executable or permission is extracted to disk. Both archive and each output are pinned.
    public static func extractRuntime(archive: URL, root: URL) throws -> URL {
        try requireSupportedHost()
        try privateDirectory(root)
        try verify(archive, asset: WriterCandidates.llamaARM64)
        let fm = FileManager.default, final = root.appendingPathComponent("llama-b9723-arm64")
        if fm.fileExists(atPath: final.path) {
            try privateDirectory(final)
            for file in runtimeFiles { try verify(final.appendingPathComponent(file.output), bytes: Int64(file.bytes), hash: file.hash) }
            return final.appendingPathComponent("libllama.0.dylib")
        }
        guard try WriterCapacity.read(at: root).freeBytes >= 32_000_000 else { throw WriterFailure.capacity }
        let staging = root.appendingPathComponent(UUID().uuidString + ".runtime-partial")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        for file in runtimeFiles {
            try Task.checkCancellation()
            let process = Process(), pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
            process.arguments = ["-xOzf", archive.path, "llama-b9723/" + file.source]
            process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
            try process.run()
            var data = Data()
            do {
                while let part = try pipe.fileHandleForReading.read(upToCount: 65_536), !part.isEmpty {
                    try Task.checkCancellation()
                    guard data.count + part.count <= file.bytes else { throw WriterFailure.integrity }
                    data.append(part)
                }
                process.waitUntilExit()
                guard process.terminationStatus == 0, data.count == file.bytes,
                      SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == file.hash else { throw WriterFailure.integrity }
            } catch { if process.isRunning { process.terminate() }; process.waitUntilExit(); throw error }
            let output = staging.appendingPathComponent(file.output)
            guard fm.createFile(atPath: output.path, contents: data, attributes: [.posixPermissions: 0o600]) else { throw WriterFailure.unavailable }
        }
        try fm.moveItem(at: staging, to: final)
        return final.appendingPathComponent("libllama.0.dylib")
    }
    struct RuntimeFile {
        let source: String; let output: String; let bytes: Int; let hash: String
        init(_ stem: String, _ version: String, _ bytes: Int, _ hash: String) {
            source = stem + "." + version + ".dylib"; output = stem + ".0.dylib"; self.bytes = bytes; self.hash = hash
        }
    }
    static let runtimeFiles = [
        RuntimeFile("libllama", "0.0.9723", 2485808, "fccced7a776b9feb53a4d20f012701c02206e1971026b6ad9879bb22b66f5f86"),
        RuntimeFile("libggml", "0.15.2", 59872, "1599fe447806f262edfe90b242eea0474ef8dc53000c2ec32cda8c180a036251"),
        RuntimeFile("libggml-base", "0.15.2", 710040, "48af0b41ea11aab73fa97616e3043ab3dffc7737de9fcd5eccd1b27e2c2a500c"),
        RuntimeFile("libggml-cpu", "0.15.2", 900912, "8e9194ce15fb2d8fb30412f31e816199e44cbe41fd625e34d57f485d548d53f5"),
        RuntimeFile("libggml-metal", "0.15.2", 832504, "1537bdd4e81d8278c3dfa7150f44646ccf74614866f4e6380512c03d6ceb2a0e"),
        RuntimeFile("libggml-blas", "0.15.2", 58776, "5169453b005f1a204cd1f15f0cfe8a3ba862f1ea28b9b143c0dee6a5cca8e97d"),
        RuntimeFile("libggml-rpc", "0.15.2", 133392, "dd55da13598a4fece656f1afa12f35493bb76fcb9afe59375e8a6d2f0372c467")
    ]
}
