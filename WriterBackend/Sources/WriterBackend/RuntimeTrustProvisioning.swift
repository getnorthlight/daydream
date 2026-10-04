import Foundation
import Security

/// Explicit setup only. Sends public signing-certificate status requests through
/// Apple trust services, never model, action or account content. No trust imports.
public enum RuntimeTrustProvisioning {
    public static let disclosure = "Checking DayDream's signature with Apple. Nothing from your history is sent."
    private static let gate = NSLock()
    private static var active = false
    private static let queue = DispatchQueue(label: "daydream.certificate-trust", qos: .utility)

    public static func prepareForExplicitLocalSetup() async throws {
        try Task.checkCancellation()
        let state = TrustProvisioningResult()
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                state.attach(continuation)
                queue.async {
                    guard !state.finished else { return }
                    gate.lock()
                    if active { gate.unlock(); state.finish(.failure(WriterFailure.busy)); return }
                    active = true; gate.unlock()
                    func release() { gate.lock(); active = false; gate.unlock() }
                    do {
                        let certificates = try preflight { if state.finished { throw CancellationError() } }
                        guard !state.finished else { release(); return }
                        var trust: SecTrust?
                        let policies = [SecPolicyCreateBasicX509(), SecPolicyCreateRevocation(CFOptionFlags(kSecRevocationUseAnyAvailableMethod | kSecRevocationRequirePositiveResponse))]
                        guard SecTrustCreateWithCertificates(certificates as CFArray, policies as CFArray, &trust) == errSecSuccess, let trust,
                              SecTrustSetNetworkFetchAllowed(trust, true) == errSecSuccess else { throw WriterFailure.trustEvidenceUnavailable }
                        guard !state.finished else { release(); return }
                        let status = SecTrustEvaluateAsyncWithError(trust, queue) { _, passed, error in
                            release()
                            state.finish(passed ? .success(()) : .failure(RuntimeSignatureVerifier.trustFailure(error.map { CFErrorGetCode($0) })))
                        }
                        if status != errSecSuccess { release(); state.finish(.failure(WriterFailure.trustEvidenceUnavailable)) }
                    } catch { release(); state.finish(.failure(error)) }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 30) { state.finish(.failure(WriterFailure.trustEvidenceUnavailable)) }
            }
            try Task.checkCancellation()
        }, onCancel: { state.finish(.failure(CancellationError())) })
    }

    // All local pins/seals checked before any network. Only the pinned host chain
    // is evaluated; all seven libraries must share that exact leaf and team.
    private static func preflight(check: () throws -> Void) throws -> [SecCertificate] {
        try check()
        guard try WriterRuntimeAdmission.requiresSignedDistribution(),
              !ProcessInfo.processInfo.environment.keys.contains(where: { $0.hasPrefix("DYLD_") }),
              let id = Bundle.main.object(forInfoDictionaryKey: "DaydreamWriterRuntimeDistribution") as? String,
              SignedRuntimeLoader.validID(id), let pin = SignedRuntimePolicy.approvedManifestSHA256[id] else { throw WriterFailure.denied }
        let root = Bundle.main.bundleURL
        guard root.pathExtension == "app" else { throw WriterFailure.denied }
        try SignedRuntimeLoader.safePath(root)
        let path = root.appendingPathComponent("Contents/Resources/WriterRuntime/" + id + ".json")
        try SignedRuntimeLoader.safePath(path)
        let bytes = try BoundedRuntimeFile.read(path, checkCancellation: check)
        guard SignedRuntimeLoader.digest(bytes) == pin else { throw WriterFailure.integrity }
        let manifest = try RuntimeManifestReader.read(bytes)
        guard manifest.distributionID == id else { throw WriterFailure.integrity }
        let (host, certificates) = try RuntimeSignatureVerifier.inspectForPreparation(root, host: true)
        guard host.identifier == Bundle.main.bundleIdentifier else { throw WriterFailure.denied }
        let directory = root.appendingPathComponent("Contents/Frameworks/WriterRuntime/" + id)
        try SignedRuntimeLoader.safePath(directory)
        let allowed = Set(manifest.files.map(\.name))
        guard allowed == Set(MacOS15Runtime.files.map(\.name)), Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == allowed else { throw WriterFailure.integrity }
        var observed: [String: (hash: String, bytes: Int64, signature: RuntimeSignatureEvidence)] = [:]
        for file in manifest.files {
            try check()
            let url = directory.appendingPathComponent(file.name)
            try SignedRuntimeLoader.safePath(url)
            try CompatibleInstallation.verify(url, bytes: file.signedBytes, hash: file.signedSHA256, checkCancellation: check)
            try RuntimeMachO.check(Data(contentsOf: url), allowed: allowed)
            observed[file.name] = (file.signedSHA256, file.signedBytes, try RuntimeSignatureVerifier.inspectForPreparation(url).0)
        }
        try SignedRuntimePolicy.check(manifest, host: host, observed: observed)
        try check()
        return certificates
    }
}

// Resolves once even when cancelled before continuation attachment. A timed-out
// OS request may finish later; it cannot resume setup or start another worker.
final class TrustProvisioningResult: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Void, Error>?
    private var continuation: CheckedContinuation<Void, Error>?
    var finished: Bool { lock.lock(); defer { lock.unlock() }; return result != nil }
    func attach(_ value: CheckedContinuation<Void, Error>) {
        lock.lock(); let saved = result
        if saved == nil { continuation = value }; lock.unlock()
        if let saved { value.resume(with: saved) }
    }
    func finish(_ value: Result<Void, Error>) {
        lock.lock(); guard result == nil else { lock.unlock(); return }
        result = value; let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: value)
    }
}
