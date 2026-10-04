import Foundation
import CryptoKit

public struct MetadataRegistration: Codable, Equatable {
    public let browser: MetadataBrowser
    public let extensionID: String
    public let publicKey: Data
    public let fingerprint: String
    public init(browser: MetadataBrowser, extensionID: String, publicKey: Data) throws {
        guard browser.acceptsExtensionID(extensionID) else { throw MetadataEnrollmentError.invalid }
        _ = try P256.Signing.PublicKey(x963Representation: publicKey)
        self.browser=browser;self.extensionID=extensionID;self.publicKey=publicKey
        self.fingerprint=SHA256.hash(data:Data("\(browser.rawValue)\n\(extensionID)\n".utf8)+publicKey).map{String(format:"%02x",$0)}.joined()
    }
}
public enum MetadataEnrollmentError: Error { case invalid, expired, unapproved, changedPin }
public struct MetadataEnrollmentChallenge {
    public let nonce: String, fingerprint: String, appFingerprint: String
    public let expiresAt: UInt64
    public let registration: MetadataRegistration
    public var signedBytes: Data {
        Data("daydream-browser-enrollment-v1\n\(registration.browser.rawValue)\n\(registration.extensionID)\n\(nonce)\n\(fingerprint)\n\(appFingerprint)".utf8)
    }
}

/// App-owned enrollment boundary. Storage callbacks must be durable and scoped
/// to the browser/extension pair; no private key is ever passed to storage.
/// Approval is a native UI action on displayed fingerprints, never a wire bool.
public final class MetadataEnrollment {
    private let appKey: P256.Signing.PrivateKey
    private let load: (MetadataBrowser,String)throws->MetadataRegistration?
    private let save: (MetadataRegistration)throws->Void
    private var pending: [MetadataBrowser: MetadataEnrollmentChallenge]=[:]
    public init(appKey: P256.Signing.PrivateKey,
                load: @escaping (MetadataBrowser,String)throws->MetadataRegistration?,
                save: @escaping (MetadataRegistration)throws->Void) {
        self.appKey=appKey;self.load=load;self.save=save
    }
    public func begin(_ candidate: MetadataRegistration, now: UInt64) throws -> MetadataEnrollmentChallenge {
        let checked=try MetadataRegistration(browser:candidate.browser,extensionID:candidate.extensionID,publicKey:candidate.publicKey)
        guard checked==candidate else {throw MetadataEnrollmentError.invalid}
        if let existing=try load(candidate.browser,candidate.extensionID),existing != candidate {throw MetadataEnrollmentError.changedPin}
        if let current=pending[candidate.browser],current.registration==candidate,now<current.expiresAt {return current}
        let challenge=MetadataEnrollmentChallenge(nonce:UUID().uuidString.lowercased(),fingerprint:candidate.fingerprint,
            appFingerprint:SHA256.hash(data:appKey.publicKey.x963Representation).map{String(format:"%02x",$0)}.joined(),
            expiresAt:now+120_000_000_000,registration:candidate)
        pending[candidate.browser]=challenge;return challenge
    }
    public func cancel(_ browser: MetadataBrowser) {pending[browser]=nil}
    public func approve(browser: MetadataBrowser, nonce: String, displayedFingerprint: String,
                        displayedAppFingerprint: String, possessionSignature: Data, now: UInt64) throws -> MetadataPins {
        let held=pending.removeValue(forKey:browser)
        guard let challenge=held,challenge.nonce==nonce else {throw MetadataEnrollmentError.invalid}
        guard now<challenge.expiresAt else {throw MetadataEnrollmentError.expired}
        guard displayedFingerprint==challenge.fingerprint,displayedAppFingerprint==challenge.appFingerprint else {throw MetadataEnrollmentError.unapproved}
        let registration=challenge.registration,key=try P256.Signing.PublicKey(x963Representation:registration.publicKey)
        guard let signature=try? P256.Signing.ECDSASignature(rawRepresentation:possessionSignature),
              key.isValidSignature(signature,for:challenge.signedBytes) else {throw MetadataEnrollmentError.invalid}
        if let existing=try load(browser,registration.extensionID) {
            guard existing==registration else {throw MetadataEnrollmentError.changedPin}
        } else {try save(registration)}
        // A save acknowledgement alone is insufficient. Read back exact public
        // registration before issuing the session pins.
        guard try load(browser,registration.extensionID)==registration else {throw MetadataEnrollmentError.invalid}
        return MetadataPins(extensionID:registration.extensionID,extensionKey:key,appKey:appKey,browser:browser)
    }
}
