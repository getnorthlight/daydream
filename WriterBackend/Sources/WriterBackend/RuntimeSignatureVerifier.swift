import Foundation
import Security
import CryptoKit

enum RuntimeSignatureVerifier {
    // CSCommon.h kSecCSNoNetworkAccess (Swift imports this as an option member).
    private static let noNetwork: UInt32 = 1 << 29
    static func requirement() throws -> SecRequirement {
        var result: SecRequirement?
        // Developer ID Application, not arbitrary Apple-issued development code.
        let text = "anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
        guard SecRequirementCreateWithString(text as CFString, [], &result) == errSecSuccess, let result else { throw WriterFailure.denied }
        return result
    }
    static func inspect(_ url: URL, host: Bool = false, revocationResponses: [Data] = []) throws -> RuntimeSignatureEvidence {
        try inspectForPreparation(url, host: host, revocationResponses: revocationResponses, requireRevocation: true).0
    }
    // Internal setup preflight only. Never used by loader to admit code.
    static func inspectForPreparation(_ url: URL, host: Bool = false, revocationResponses: [Data] = [], requireRevocation: Bool = false) throws -> (RuntimeSignatureEvidence, [SecCertificate]) {
        guard revocationResponses.count <= 8, revocationResponses.allSatisfy({!$0.isEmpty && $0.count <= 65_536}) else {throw WriterFailure.invalidInput}
        let requirement = try requirement()
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { throw WriterFailure.denied }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | noNetwork)
        guard SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw WriterFailure.denied }
        if host {
            var running: SecCode?; var runningPath: CFURL?; var runningStatic: SecStaticCode?
            guard SecCodeCopySelf([], &running) == errSecSuccess, let running,
                  SecCodeCheckValidity(running, SecCSFlags(rawValue: noNetwork), requirement) == errSecSuccess,
                  SecCodeCopyStaticCode(running, [], &runningStatic) == errSecSuccess, let runningStatic,
                  SecCodeCopyPath(runningStatic, [], &runningPath) == errSecSuccess, let runningPath,
                  WriterPaths.same(runningPath as URL, url)
            else { throw WriterFailure.denied }
        }
        var raw: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &raw) == errSecSuccess,
              let info = raw as? [String: Any],
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
              let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first
        else { throw WriterFailure.denied }
        if requireRevocation {
        var trust: SecTrust?
        // Offline, fail closed if cached/system trust cannot establish revocation.
        let policies = [SecPolicyCreateBasicX509(), SecPolicyCreateRevocation(CFOptionFlags(kSecRevocationUseAnyAvailableMethod | kSecRevocationRequirePositiveResponse | kSecRevocationNetworkAccessDisabled))]
        guard SecTrustCreateWithCertificates(certs as CFArray, policies as CFArray, &trust) == errSecSuccess, let trust,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else { throw WriterFailure.denied }
        // Untrusted stapled DER responses, not a caller assertion of trust. Security
        // validates issuer/signature/serial/freshness/status against the actual chain.
        if !revocationResponses.isEmpty {
            guard SecTrustSetOCSPResponse(trust, revocationResponses as CFArray) == errSecSuccess else {throw WriterFailure.trustEvidenceUnavailable}
        }
        var trustError: CFError?
        guard SecTrustEvaluateWithError(trust, &trustError) else {
            let code = trustError.map { CFErrorGetCode($0) }
            throw trustFailure(code)
        }
        }
        if let value = info[kSecCodeInfoEntitlementsDict as String], !(value is [String: Any]) { throw WriterFailure.denied }
        let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let hash = SHA256.hash(data: SecCertificateCopyData(leaf) as Data).map { String(format: "%02x", $0) }.joined()
        return (RuntimeSignatureEvidence(validDeveloperIDChain: true, teamID: team, certificateSHA256: hash,
            identifier: identifier, hardenedRuntime: flags.uint32Value & 0x10000 != 0,
            adHoc: flags.uint32Value & 0x2 != 0, entitlementKeys: Set(entitlements.keys)), certs)
    }
    static func trustFailure(_ code: Int?) -> WriterFailure {
        if code == Int(errSecCertificateRevoked) || code == Int(errSecCertificateExpired) || code == Int(errSecCertificateNotValidYet) {return .denied}
        return .trustEvidenceUnavailable
    }
}
