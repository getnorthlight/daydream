import Foundation

/// Rebuilt reviewed source, not the upstream min-26 release bytes. No downloads.
/// Reproducible build: WriterBackend/build_macos15_runtime.py (recipe in WriterBackend/PROVENANCE.md).
public enum MacOS15Runtime {
    public static let id = "llama-b9723-macos15-arm64-v2"
    public static let sourceCommit = "b14e3fb90ca8c760f4254ddc9aa7845ebbdb2edf"
    public static let sourceArchiveSHA256 = "55d57e59cccd163526290a3d369356e2818343febb83fe39d6731056a15a5cb4"
    /// SHA-256 of the canonical uncompressed tar of exactly the seven unsigned `files` below plus the
    /// llama.cpp MIT licence as `runtime-LICENSE`, with fixed metadata (WriterBackend/macos15_runtime_archive.py).
    /// It depends only on those eight files' bytes, so any rebuild that reproduces them reproduces this hash.
    public static let archiveSHA256 = "714bdf726e3c9c6c81f346dc87c1188c8c4e5ae4bdb93a1ec690f4a73252672d"
    public static let signedSchema = "daydream-signed-runtime/macos15-v2"
    public static func supports(osMajor:Int, architecture:String) -> Bool {osMajor >= 15 && architecture == "arm64"}
    static let files:[(name:String,bytes:Int64,hash:String)] = [
        ("libllama.0.dylib",2469424,"ae33ee5d7acc95a58fa9bad0fc908db42059a8943c29e344b3fe70fd0532902d"),
        ("libggml.0.dylib",59872,"b8742eaf98f2a33c7c7f953b7d6ace16e0ef47438b94650d7a87d4b86da1dde7"),
        ("libggml-base.0.dylib",710040,"6db3ed93964340d9319f9f19ad196cf914b6886fcbc09d7776b2fb21ccc5623b"),
        ("libggml-cpu.0.dylib",917424,"21dd443b21e656a8a041e2cd66174f67da454fa42977bfd106c0d1a6ee79f0de"),
        ("libggml-metal.0.dylib",832504,"32a8f0f4cd9a145aa040402c5b22968c984a17930cbafd7de471067fece81b72"),
        ("libggml-blas.0.dylib",58776,"4a694d43d1babd66ca473335120a3221b422f8924a4e86ec8fc0e8939d56d031"),
        ("libggml-rpc.0.dylib",133392,"37236a0aa3e46cc577ed19c41c3f10645a1ad3d130f4eae234162b516ae2912f")
    ]
    /// Explicit development trial only. A signed host must use enrolled signed distribution.
    public static func validateTrial(model:URL, directory:URL) throws -> CompatibleWriterFiles {
        guard try !WriterRuntimeAdmission.requiresSignedDistribution() else {throw WriterFailure.denied}
        #if arch(arm64)
        let architecture="arm64"
        #else
        let architecture="unsupported"
        #endif
        guard supports(osMajor:ProcessInfo.processInfo.operatingSystemVersion.majorVersion,architecture:architecture),let plan=WriterCandidates.recommended else {throw WriterFailure.incompatible}
        guard ProcessInfo.processInfo.physicalMemory >= plan.minimumMemory else {throw WriterFailure.capacity}
        try CompatibleInstallation.privateDirectory(directory)
        try PersistentModelCache.verify(model,asset:plan.asset)
        let expected=Set(files.map(\.name))
        guard Set(try FileManager.default.contentsOfDirectory(atPath:directory.path)) == expected else {throw WriterFailure.integrity}
        for file in files {
            let path=directory.appendingPathComponent(file.name)
            try CompatibleInstallation.verify(path,bytes:file.bytes,hash:file.hash)
            try RuntimeMachO.check(Data(contentsOf:path),allowed:expected,allowUpstreamRpath:true)
        }
        return CompatibleWriterFiles(model:model,library:directory.appendingPathComponent("libllama.0.dylib"),derivation:id)
    }
}
