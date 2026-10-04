import Foundation

// Internal evidence policy used by SignedRuntimeLoader. No signing or identity discovery.
// Kept internal: callers cannot turn their own hashes into loader authority.
struct SignedRuntimeManifest: Codable {
    var schema: String
    var distributionID: String
    var upstreamArchiveSHA256: String
    var teamID: String
    var certificateSHA256: String
    var files: [File]
    struct File: Codable {
        var name: String
        var upstreamSHA256: String
        var signedSHA256: String
        var signedBytes: Int64
        var signingIdentifier: String
    }
}

struct RuntimeSignatureEvidence {
    var validDeveloperIDChain: Bool
    var teamID: String
    var certificateSHA256: String
    var identifier: String
    var hardenedRuntime: Bool
    var adHoc: Bool
    // All entitlement keys, including false-valued keys. Runtime libraries require none.
    var entitlementKeys: Set<String>
}

enum SignedRuntimePolicy {
    // Exact root-approved final signed bytes, independently audited 2026-09-14.
    // See WriterBackend/PROVENANCE.md and docs/summaries.md. Pins do not waive signature/trust checks.
    // No network, environment, preference, manifest-sibling or first-use enrollment.
    static let approvedManifestSHA256: [String: String] = [
        "daydream-qwen35-b9723-macos15-v2": "c6707fc5688f52e9bd860ce4bd37d4f9198d11e19c85c8a1e08d66114ff17f75"
    ]

    static func isApproved(distributionID: String, manifestSHA256: String) -> Bool {
        approvedManifestSHA256[distributionID] == manifestSHA256
    }

    // Pure contract validation. Passing this does NOT grant approval or load authority.
    static func check(_ manifest: SignedRuntimeManifest, host: RuntimeSignatureEvidence,
                      observed: [String: (hash: String, bytes: Int64, signature: RuntimeSignatureEvidence)]) throws {
        let rebuilt = manifest.schema == MacOS15Runtime.signedSchema
        guard (manifest.schema == "daydream-signed-runtime/v1" || rebuilt),
              !manifest.distributionID.isEmpty,
              manifest.upstreamArchiveSHA256 == (rebuilt ? MacOS15Runtime.archiveSHA256 : WriterCandidates.llamaARM64.sha256),
              manifest.teamID.count == 10,
              manifest.teamID.allSatisfy({ $0.isASCII && ($0.isUppercase || $0.isNumber) }),
              digest(manifest.certificateSHA256),
              host.validDeveloperIDChain, !host.adHoc, host.hardenedRuntime,
              host.teamID == manifest.teamID,
              host.certificateSHA256 == manifest.certificateSHA256,
              host.entitlementKeys.isSubset(of: ["com.apple.security.automation.apple-events"])
        else { throw WriterFailure.denied }
        let upstream = Dictionary(uniqueKeysWithValues: rebuilt ? MacOS15Runtime.files.map { ($0.name, $0.hash) } : CompatibleInstallation.runtimeFiles.map { ($0.output, $0.hash) })
        guard manifest.files.count == upstream.count,
              Set(manifest.files.map(\.name)) == Set(upstream.keys),
              Set(observed.keys) == Set(upstream.keys) else { throw WriterFailure.integrity }
        for file in manifest.files {
            guard file.upstreamSHA256 == upstream[file.name], digest(file.signedSHA256),
                  file.signedSHA256 != file.upstreamSHA256, file.signedBytes > 0,
                  !file.signingIdentifier.isEmpty, let actual = observed[file.name],
                  actual.hash == file.signedSHA256, actual.bytes == file.signedBytes
            else { throw WriterFailure.integrity }
            let signature = actual.signature
            guard signature.validDeveloperIDChain, !signature.adHoc, signature.hardenedRuntime,
                  signature.teamID == manifest.teamID,
                  signature.certificateSHA256 == manifest.certificateSHA256,
                  signature.identifier == file.signingIdentifier,
                  signature.entitlementKeys.isEmpty else { throw WriterFailure.denied }
        }
    }
    private static func digest(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy { "0123456789abcdef".contains($0) }
    }
}
