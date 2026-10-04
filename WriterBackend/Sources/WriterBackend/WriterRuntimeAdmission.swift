import Foundation
import Security

/// Inspects this process only, never signing identities or Keychain credentials.
public enum WriterRuntimeAdmission {
    public static func requiresSignedDistribution() throws -> Bool {
        var running: SecCode?; var code: SecStaticCode?; var raw: CFDictionary?
        guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
              SecCodeCopyStaticCode(running, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any], let flags = info[kSecCodeInfoFlags as String] as? NSNumber else { throw WriterFailure.denied }
        return requiresSignedDistribution(adHoc: flags.uint32Value & 2 != 0, hasTeam: info[kSecCodeInfoTeamIdentifier as String] != nil)
    }
    static func requiresSignedDistribution(adHoc: Bool, hasTeam: Bool) -> Bool { !adHoc || hasTeam }
    /// A signed app that ships without the enrolled runtime can never load a local writer,
    /// so setup must stop before downloading the model.
    public static func signedPayloadMissing() throws -> Bool {
        guard try requiresSignedDistribution() else { return false }
        guard let id = Bundle.main.object(forInfoDictionaryKey: "DaydreamWriterRuntimeDistribution") as? String, !id.isEmpty else { return true }
        let root = Bundle.main.bundleURL, files = FileManager.default
        return !files.fileExists(atPath: root.appendingPathComponent("Contents/Resources/WriterRuntime/" + id + ".json").path)
            || !files.fileExists(atPath: root.appendingPathComponent("Contents/Frameworks/WriterRuntime/" + id).path)
    }
    public static func restore(modelRoot: URL, revocationResponses: [Data] = []) async throws -> CompatibleWriterFiles {
        guard let model = try await PersistentModelCache.discover(in: PersistentModelCache.searchRoots(for:modelRoot)) else {throw WriterFailure.unavailable}
        if try requiresSignedDistribution() {
            guard let release = Bundle.main.object(forInfoDictionaryKey: "DaydreamWriterRuntimeDistribution") as? String else { throw WriterFailure.denied }
            return try await SignedRuntimeLoader.restore(model: model, distributionID: release, revocationResponses: revocationResponses)
        }
        return try CompatibleInstallation.validate(model:model,runtimeDirectory:modelRoot.appendingPathComponent("llama-b9723-arm64"))
    }
}
