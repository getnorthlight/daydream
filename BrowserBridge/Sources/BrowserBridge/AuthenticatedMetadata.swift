import Foundation
import CryptoKit

public enum MetadataBrowser: String, Codable {
    case chrome, safari
    public var bundle: String { self == .chrome ? "com.google.Chrome" : "com.apple.Safari" }
    public func acceptsExtensionID(_ value: String) -> Bool {
        let pattern = self == .chrome ? "^[a-p]{32}$" : "^[A-Za-z0-9][A-Za-z0-9._-]{1,199}$"
        return value.range(of: pattern, options: .regularExpression) != nil
    }
}

/// Browser-owned metadata ONLY. Never a native AX focus or typing witness.
/// Pins come from reviewed app/extension enrollment, not hello/argv/wire JSON.
public struct MetadataPins {
    public let browser: MetadataBrowser
    public let extensionID: String
    public let extensionKey: P256.Signing.PublicKey
    public let appKey: P256.Signing.PrivateKey
    public init(extensionID: String, extensionKey: P256.Signing.PublicKey, appKey: P256.Signing.PrivateKey, browser: MetadataBrowser = .chrome) {
        self.browser = browser
        self.extensionID = extensionID; self.extensionKey = extensionKey; self.appKey = appKey
    }
}

/// Supplied fresh by the app capture executor, before requesting AND accepting.
/// Does not pretend to map an AX window to a Chrome window ID.
public struct MetadataGate {
    public var frontmostBrowserBundle = ""
    public var frontmostChrome = false, secureInputOff = false, permissionPresent = false
    public var captureEnabled = false, excluded = true
    public var generation = 0
    public var checkedAt: UInt64 = 0
    public init() {}
    func valid(_ now: UInt64, browser: MetadataBrowser) -> Bool {
        (frontmostBrowserBundle == browser.bundle || (browser == .chrome && frontmostBrowserBundle.isEmpty && frontmostChrome)) && secureInputOff && permissionPresent && captureEnabled && !excluded &&
        generation > 0 && now >= checkedAt && now - checkedAt <= 500_000_000
    }
}

public struct SignedMetadataFrame: Codable {
    public let browser: MetadataBrowser
    public let version: Int
    public let extensionID: String, clientNonce: String, sessionID: String
    public let sequence: Int
    public let payload: String, signature: String
    static let keys: Set<String> = ["version", "browser", "extensionID", "clientNonce", "sessionID", "sequence", "payload", "signature"]
    public static func decode(_ data: Data) -> Self? {
        guard data.count <= NativeFrames.limit,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], Set(json.keys) == keys,
              let frame = try? JSONDecoder().decode(Self.self, from: data), frame.version == 3,
              frame.browser.acceptsExtensionID(frame.extensionID),
              token(frame.clientNonce), token(frame.sessionID), frame.sequence > 0, frame.sequence <= 9_007_199_254_740_991,
              let bytes = Data(base64Encoded: frame.payload), bytes.count <= 2600,
              let sig = Data(base64Encoded: frame.signature), sig.count == 64 else { return nil }
        return frame
    }
    static func token(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{32}$", options: .regularExpression) != nil }
    public func signedBytes(direction: String) -> Data {
        Data("daydream-browser-metadata-v3\n\(direction)\n\(browser.rawValue)\n\(extensionID)\n\(clientNonce)\n\(sessionID)\n\(sequence)\n\(payload)".utf8)
    }
    public static func sign(payload: Data, extensionID: String, clientNonce: String, sessionID: String,
                            sequence: Int, direction: String, key: P256.Signing.PrivateKey, browser: MetadataBrowser = .chrome) throws -> Data {
        let unsigned = Self(browser: browser, version: 3, extensionID: extensionID, clientNonce: clientNonce, sessionID: sessionID,
                            sequence: sequence, payload: payload.base64EncodedString(), signature: "")
        let signature = try key.signature(for: unsigned.signedBytes(direction: direction)).rawRepresentation.base64EncodedString()
        let data = try JSONEncoder().encode(Self(browser: browser, version: 3, extensionID: extensionID, clientNonce: clientNonce,
            sessionID: sessionID, sequence: sequence, payload: unsigned.payload, signature: signature))
        guard Self.decode(data) != nil else { throw NativeFrameError.oversized }
        return data
    }
    func verified(_ key: P256.Signing.PublicKey, direction: String) -> Data? {
        guard let raw = Data(base64Encoded: signature), let sig = try? P256.Signing.ECDSASignature(rawRepresentation: raw),
              key.isValidSignature(sig, for: signedBytes(direction: direction)) else { return nil }
        return Data(base64Encoded: payload)
    }
}

public struct BrowserOwnedMetadata {
    public let browser: MetadataBrowser
    public let kind: String // browser.extension_observed / browser.extension_tab_visited
    public let observation: BrowserObservation // Browser IDs only. No native IDs or text.
    public let sessionID: String
    public let checkedAt: UInt64, continuousNanoseconds: UInt64
}

/// One connection; close permanently on transport loss. No writer, OS reader,
/// enrollment, persisted keys, listener service or production enabling switch.
public final class AuthenticatedMetadataSession {
    public private(set) var status = "awaiting_policy"
    public let textEnabled = false
    private let pins: MetadataPins, clientNonce: String
    public let sessionID = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    private var sequence = 0, closed = false, latestGeneration = 0
    private var lastRequest: UInt64?
    private var pending: (nonce: String, at: UInt64, sequence: Int, generation: Int, policy: BridgePolicy)?
    private var visit: (identity: String, first: UInt64, sampled: UInt64, emitted: Bool)?
    public init?(pins: MetadataPins, clientNonce: String) {
        guard pins.browser.acceptsExtensionID(pins.extensionID),
              SignedMetadataFrame.token(clientNonce) else { return nil }
        self.pins = pins; self.clientNonce = clientNonce
    }
    public func invalidate() { pending = nil; visit = nil; status = "invalidated" }
    public func close() { invalidate(); closed = true; status = "disconnected" }
    public func request(policy: BridgePolicy, gate: MetadataGate, now: UInt64,
                        privacyAllowsOrigins: (Set<String>) -> Bool,
                        privacyAllowsOrdinaryMetadata: () -> Bool = {false}) -> Data? {
        guard !closed,policy.enabled,gate.valid(now,browser:pins.browser) else {invalidate();return nil}
        let originsOK = policy.ordinaryMetadata
            ? policy.allowedOrigins.isEmpty && privacyAllowsOrdinaryMetadata()
            : !policy.allowedOrigins.isEmpty && policy.allowedOrigins.count <= 16 &&
                policy.allowedOrigins.allSatisfy(BrowserReceiver.originOnly) && privacyAllowsOrigins(policy.allowedOrigins)
        guard !closed, policy.enabled, policy.revision > 0, gate.valid(now, browser: pins.browser),
              originsOK, policy.excludedDomains.count<=64, policy.excludedDomains.allSatisfy(Self.domain),
              pending == nil, lastRequest.map({ now >= $0 && now - $0 >= 100_000_000 }) ?? true else {
            invalidate(); status = "policy_or_fresh_gate_missing"; return nil
        }
        sequence += 1
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let probe = Probe(nonce: nonce, policyRevision: policy.revision, allowedOrigins: policy.allowedOrigins.sorted(),
            ordinaryMetadata:policy.ordinaryMetadata ? true : nil,excludedDomains:policy.ordinaryMetadata ? policy.excludedDomains.sorted() : nil)
        guard let payload = try? JSONEncoder().encode(probe), let signed = try? SignedMetadataFrame.sign(payload: payload,
            extensionID: pins.extensionID, clientNonce: clientNonce, sessionID: sessionID, sequence: sequence,
            direction: "app-to-extension", key: pins.appKey, browser: pins.browser) else { invalidate(); return nil }
        pending = (nonce, now, sequence, gate.generation, policy); lastRequest = now; status = "awaiting_signed_observation"
        return signed
    }
    public func receive(_ data: Data, policy: BridgePolicy, gate: MetadataGate, now: UInt64,
                        privacyAllowsMetadata: (BrowserObservation) -> Bool) -> BrowserOwnedMetadata? {
        let expected = pending; pending = nil // one attempt, including rejects
        guard !closed, let p = expected, now >= p.at, now - p.at <= 1_000_000_000,
              policy.enabled, policy.revision == p.policy.revision, policy.allowedOrigins == p.policy.allowedOrigins,
              policy.ordinaryMetadata==p.policy.ordinaryMetadata,policy.excludedDomains==p.policy.excludedDomains,
              gate.valid(now, browser: pins.browser), gate.generation == p.generation,
              let frame = SignedMetadataFrame.decode(data), frame.browser == pins.browser, frame.extensionID == pins.extensionID,
              frame.clientNonce == clientNonce, frame.sessionID == sessionID, frame.sequence == p.sequence,
              let payload = frame.verified(pins.extensionKey, direction: "extension-to-app"),
              let e = BrowserObservation.decode(payload), e.version == 1, e.kind == "observation", !e.textEnabled,
              e.nonce == p.nonce, e.policyRevision == policy.revision,
              e.windowMode == "normal", e.tabMode == "normal", e.windowID >= 0, e.tabID >= 0, e.frameID == 0,
              UUID(uuidString: e.documentID) != nil, UUID(uuidString: e.focusID) != nil,
              e.navigationGeneration > 0, e.navigationGeneration >= latestGeneration, e.focusGeneration > 0,
              ["button", "link", "document"].contains(e.role), e.safety == "noneditable",
              BrowserReceiver.originOnly(e.origin), (policy.ordinaryMetadata || policy.allowedOrigins.contains(e.origin)),
              !Self.excluded(e.origin,policy.excludedDomains),privacyAllowsMetadata(e) else {
            visit = nil; status = "signed_observation_denied"; return nil
        }
        latestGeneration = e.navigationGeneration
        let identity = "\(e.windowID)/\(e.tabID)/\(e.documentID)/\(e.navigationGeneration)/\(e.focusID)/\(e.focusGeneration)/\(e.origin)/\(policy.revision)/\(gate.generation)"
        if visit?.identity != identity || now < (visit?.sampled ?? now) || now - (visit?.sampled ?? now) > 1_000_000_000 {
            visit = (identity, now, now, false)
        }
        let elapsed = now - visit!.first, emit = elapsed >= 10_000_000_000 && !visit!.emitted
        visit = (identity, visit!.first, now, visit!.emitted || emit); status = "browser_owned_metadata_verified"
        return BrowserOwnedMetadata(browser: pins.browser, kind: emit ? "browser.extension_tab_visited" : "browser.extension_observed",
            observation: e, sessionID: sessionID, checkedAt: now, continuousNanoseconds: elapsed)
    }
    static func domain(_ raw:String)->Bool {
        raw.utf8.count<=253 && raw.range(of:"^[a-z0-9]+(?:[.-][a-z0-9]+)*$",options:.regularExpression) != nil
    }
    static func excluded(_ origin:String,_ domains:Set<String>)->Bool {
        guard let host=URLComponents(string:origin)?.host?.lowercased() else {return true}
        return domains.contains{host==$0 || host.hasSuffix("."+$0)}
    }
}
