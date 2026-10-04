import Foundation
import CryptoKit

/// Explicit signed mode. Unknown release IDs fail before filesystem or signature work.
/// Never installs, enrolls a caller hash or falls back to the upstream trial runtime.
public enum SignedRuntimeLoader {
    public static func restore(model: URL, distributionID: String, revocationResponses: [Data] = []) async throws -> CompatibleWriterFiles {
        let worker = Task.detached(priority: .utility) { try validate(model: model, distributionID: distributionID, revocationResponses: revocationResponses) }
        return try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
    }
    /// fix/sx-engine-battery: the runtime's signatures (the app and its seven libraries, with the certificate status saved
    /// on this Mac) are validated once per process. Later activations and every model load reuse that result while each
    /// library file is still the one that was checked (its metadata only). The model file is checked separately
    /// (`ModelIdentity`: hashed once per activation, metadata per load).
    private struct Validated { let files: CompatibleWriterFiles; let identities: [String: ModelIdentity.Identity]; let at: Date }
    private static let validatedLock = NSLock()
    nonisolated(unsafe) private static var validated: [String: Validated] = [:]
    nonisolated(unsafe) private static var lastRefresh = Date.distantPast
    /// How many times this process validated the runtime's signatures in full (checks read it).
    nonisolated(unsafe) public private(set) static var fullValidations = 0
    private static func cached(_ distributionID: String, directory: URL) -> Validated? {
        validatedLock.lock(); let known = validated[distributionID]; validatedLock.unlock()
        guard let known, known.identities.count == CompatibleInstallation.runtimeFiles.count else { return nil }
        for (name, identity) in known.identities {
            guard (try? ModelIdentity.identity(directory.appendingPathComponent(name))) == identity else { return nil }
        }
        return known
    }
    static func validate(model: URL, distributionID: String, revocationResponses: [Data] = [], checkModel: Bool = true, checkCancellation: () throws -> Void = {try Task.checkCancellation()}) throws -> CompatibleWriterFiles {
        try checkCancellation()
        // Cheap checks first (pins, OS, memory, folders); the model hash, the costliest, comes last.
        let directory = Bundle.main.bundleURL.appendingPathComponent("Contents/Frameworks/WriterRuntime/" + distributionID)
        if let known = cached(distributionID, directory: directory), SignedRuntimePolicy.approvedManifestSHA256[distributionID] != nil,
           !ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("DYLD_") }) {
            try CompatibleInstallation.privateDirectory(model.deletingLastPathComponent())
            if checkModel, let plan = WriterCandidates.recommended { try ModelIdentity.verify(model, bytes: plan.asset.bytes, hash: plan.asset.sha256, checkCancellation: checkCancellation) }
            // Certificate status older than a day: refreshed in the background from Apple (public certificate status
            // only, never history), while this session keeps the check it already passed.
            refreshTrustIfStale(since: known.at)
            return CompatibleWriterFiles(model: model, library: known.files.library, signedDistributionID: distributionID, revocationResponses: known.files.revocationResponses, derivation: known.files.derivation)
        }
        let files = try validateFully(model: model, distributionID: distributionID, revocationResponses: revocationResponses, checkModel: checkModel, checkCancellation: checkCancellation)
        var identities: [String: ModelIdentity.Identity] = [:]
        for name in CompatibleInstallation.runtimeFiles.map(\.output) {
            if let identity = try? ModelIdentity.identity(files.library.deletingLastPathComponent().appendingPathComponent(name)) { identities[name] = identity }
        }
        validatedLock.lock(); validated[distributionID] = Validated(files: files, identities: identities, at: Date()); fullValidations += 1; validatedLock.unlock()
        return files
    }
    private static func refreshTrustIfStale(since: Date) {
        validatedLock.lock()
        let due = Date().timeIntervalSince(max(since, lastRefresh)) > 24 * 3600
        if due { lastRefresh = Date() }
        validatedLock.unlock()
        guard due else { return }
        Task.detached(priority: .background) { try? await RuntimeTrustProvisioning.prepareForExplicitLocalSetup() }
    }
    private static func validateFully(model: URL, distributionID: String, revocationResponses: [Data], checkModel: Bool, checkCancellation: () throws -> Void) throws -> CompatibleWriterFiles {
        try checkCancellation()
        guard let pin = SignedRuntimePolicy.approvedManifestSHA256[distributionID],
              validID(distributionID),
              !ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("DYLD_") })
        else { throw WriterFailure.denied }
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "unsupported"
        #endif
        guard MacOS15Runtime.supports(osMajor: ProcessInfo.processInfo.operatingSystemVersion.majorVersion, architecture: arch),
              let plan = WriterCandidates.recommended else { throw WriterFailure.incompatible }
        guard ProcessInfo.processInfo.physicalMemory >= plan.minimumMemory else { throw WriterFailure.capacity }
        try CompatibleInstallation.privateDirectory(model.deletingLastPathComponent())
        let bundle = Bundle.main
        let root = bundle.bundleURL
        guard root.pathExtension == "app", let identifier = bundle.bundleIdentifier else { throw WriterFailure.denied }
        try safePath(root)
        let manifestURL = root.appendingPathComponent("Contents/Resources/WriterRuntime/" + distributionID + ".json")
        try safePath(manifestURL)
        let data = try BoundedRuntimeFile.read(manifestURL, checkCancellation: checkCancellation)
        guard data.count <= 32_768, digest(data) == pin else { throw WriterFailure.integrity }
        let manifest = try RuntimeManifestReader.read(data)
        let minimumOS = manifest.schema == MacOS15Runtime.signedSchema ? 15 : 26
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= minimumOS else {throw WriterFailure.incompatible}
        guard manifest.distributionID == distributionID else { throw WriterFailure.integrity }
        try checkCancellation()
        let host = try RuntimeSignatureVerifier.inspect(root, host: true, revocationResponses: revocationResponses)
        try checkCancellation()
        guard host.identifier == identifier else { throw WriterFailure.denied }
        let directory = root.appendingPathComponent("Contents/Frameworks/WriterRuntime/" + distributionID)
        try safePath(directory)
        let expected = Set(CompatibleInstallation.runtimeFiles.map(\.output))
        guard Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == expected else { throw WriterFailure.integrity }
        var observed: [String: (hash: String, bytes: Int64, signature: RuntimeSignatureEvidence)] = [:]
        for file in manifest.files {
            try checkCancellation()
            guard expected.contains(file.name), file.signedBytes > 0, file.signedBytes <= 32_000_000 else { throw WriterFailure.integrity }
            let url = directory.appendingPathComponent(file.name); try safePath(url)
            try CompatibleInstallation.verify(url, bytes: file.signedBytes, hash: file.signedSHA256, checkCancellation: checkCancellation)
            try RuntimeMachO.check(Data(contentsOf: url), allowed: expected)
            observed[file.name] = (file.signedSHA256, file.signedBytes, try RuntimeSignatureVerifier.inspect(url, revocationResponses: revocationResponses))
            try checkCancellation()
        }
        try SignedRuntimePolicy.check(manifest, host: host, observed: observed)
        if checkModel { try ModelIdentity.verify(model, bytes: plan.asset.bytes, hash: plan.asset.sha256, checkCancellation: checkCancellation) }
        return CompatibleWriterFiles(model: model, library: directory.appendingPathComponent("libllama.0.dylib"), signedDistributionID: distributionID, revocationResponses: revocationResponses,derivation:manifest.schema == MacOS15Runtime.signedSchema ? MacOS15Runtime.id : "qwen3.5-4b-q4km-llama-b9723-v1")
    }
    static func validID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 96 && value.allSatisfy { "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_".contains($0) }
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    /// The app's own folder passes the same check the signed runtime gets (`safePath`). It fails on a drive whose root is
    /// group-writable (an external disk, mounted without owners) and for a translocated or disk-image copy: the runtime
    /// can never load there, whatever the model, so setup says to move DayDream instead of "The model couldn't start."
    public static func appLocationAllowed(_ bundle: URL = Bundle.main.bundleURL) -> Bool { (try? safePath(bundle)) != nil }
    static func safePath(_ url: URL) throws {
        guard url.path == url.resolvingSymlinksInPath().path else { throw WriterFailure.denied }
        var current = url
        while current.path != "/" {
            let attrs = try FileManager.default.attributesOfItem(atPath: current.path)
            guard attrs[.type] as? FileAttributeType != .typeSymbolicLink,
                  let mode = attrs[.posixPermissions] as? NSNumber,
                  let uid = attrs[.ownerAccountID] as? NSNumber, let gid = attrs[.groupOwnerAccountID] as? NSNumber,
                  permissionsAllowed(path: current.path, uid: uid.intValue, gid: gid.intValue, mode: mode.intValue) else { throw WriterFailure.denied }
            current.deleteLastPathComponent()
        }
    }
    static func permissionsAllowed(path: String, uid: Int, gid: Int, mode: Int) -> Bool {
        // Only this exact system-managed anchor may be group-writable by admin (gid 80).
        if path == "/Applications" { return uid == 0 && (gid == 0 || gid == 80) && mode & 0o002 == 0 && (mode & 0o020 == 0 || gid == 80) }
        return (uid == 0 || uid == Int(geteuid())) && mode & 0o022 == 0
    }
}

// Bounded parser for the approved thin ARM64 dylib distribution, not a general Mach-O reader.
enum RuntimeMachO {
    static func check(_ data: Data, allowed: Set<String>, allowUpstreamRpath: Bool = false) throws {
        let bytes = Array(data)
        func word(_ offset: Int) throws -> UInt32 {
            guard offset >= 0, offset + 4 <= bytes.count else { throw WriterFailure.integrity }
            return (0..<4).reduce(0) { $0 | UInt32(bytes[offset + $1]) << ($1 * 8) }
        }
        guard try word(0) == 0xfeedfacf, try word(4) == 0x0100000c, try word(12) == 6 else { throw WriterFailure.incompatible }
        let count = Int(try word(16)), end = 32 + Int(try word(20))
        guard count <= 256, end <= bytes.count else { throw WriterFailure.integrity }
        var cursor = 32, hasLoaderPath = false, needsLoaderPath = false
        for _ in 0..<count {
            let command = try word(cursor), size = Int(try word(cursor + 4))
            guard size >= 8, size % 4 == 0, cursor + size <= end else { throw WriterFailure.integrity }
            guard command != 0x27, command != 0xe else { throw WriterFailure.denied }
            if [UInt32(0xc), 0xd, 0x80000018, 0x8000001f, 0x20, 0x80000023, 0x8000001c].contains(command) {
                let offset = Int(try word(cursor + 8))
                guard offset >= 12, offset < size, let nul = bytes[(cursor + offset)..<(cursor + size)].firstIndex(of: 0),
                      let path = String(bytes: bytes[(cursor + offset)..<nul], encoding: .utf8) else { throw WriterFailure.integrity }
                if command == 0x8000001c {
                    guard path == "@loader_path" else { throw WriterFailure.denied }
                    hasLoaderPath = true
                } else {
                    let local = allowed.contains(String(path.dropFirst("@rpath/".count))) && path.hasPrefix("@rpath/")
                    let loader = allowed.contains(String(path.dropFirst("@loader_path/".count))) && path.hasPrefix("@loader_path/")
                    let system = (path.hasPrefix("/usr/lib/") || path.hasPrefix("/System/Library/Frameworks/")) && !path.contains("..")
                    // Signed distributions require transformed @loader_path references.
                    // No host/inherited rpath chain can select a different dependency.
                    guard (local && (allowUpstreamRpath || command == 0xd)) || loader || system else { throw WriterFailure.denied }
                    if local && command != 0xd { needsLoaderPath = true }
                }
            }
            cursor += size
        }
        guard cursor == end, !needsLoaderPath || hasLoaderPath else { throw WriterFailure.integrity }
    }
}
