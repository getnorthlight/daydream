import Foundation
import CryptoKit

public enum DiagnosticError: Error { case invalid, expired, closed, unavailable, io }
public struct DiagnosticBinding: Codable, Equatable {
    public let browser:String, extensionID:String, appFingerprint:String, extensionFingerprint:String
    public let deployment:String, configuration:String
    public init(browser:String,extensionID:String,appFingerprint:String,extensionFingerprint:String,deployment:String,configuration:String)throws {
        guard ["chrome","safari"].contains(browser),
              Self.matches(extensionID,browser=="chrome" ? "^[a-p]{32}$" : "^[A-Za-z0-9][A-Za-z0-9._-]{1,199}$"),
              [appFingerprint,extensionFingerprint,deployment,configuration].allSatisfy({Self.matches($0,"^[a-f0-9]{64}$")}) else {throw DiagnosticError.invalid}
        self.browser=browser;self.extensionID=extensionID;self.appFingerprint=appFingerprint
        self.extensionFingerprint=extensionFingerprint;self.deployment=deployment;self.configuration=configuration
    }
    static func matches(_ text:String,_ regex:String)->Bool {text.range(of:regex,options:.regularExpression) != nil}
    public static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    public static func extensionDigest(browser:String,extensionID:String,key:Data)->String {
        digest(Data((browser+"\n"+extensionID+"\n").utf8)+key)
    }
}
public struct DiagnosticFrame: Codable, Equatable {
    public static let domain="daydream-browser-diagnostic-v1"
    public let protocolName:String, kind:String, binding:DiagnosticBinding, attemptID:String, clientNonce:String
    public let expiresAt:Int64
    public let signature:String
    enum CodingKeys:String,CodingKey {case protocolName="protocol",kind,binding,attemptID,clientNonce,expiresAt,signature}
    public static func encode<T:Encodable>(_ value:T)throws->Data {
        let e=JSONEncoder();e.outputFormatting=[.sortedKeys,.withoutEscapingSlashes];return try e.encode(value)
    }
    public static func decode(_ data:Data)throws->Self {
        guard data.count>0,data.count<=4096 else {throw DiagnosticError.invalid}
        let f=try JSONDecoder().decode(Self.self,from:data)
        // Canonical equality rejects unknown/duplicate fields, alternate types and hidden payloads.
        guard try encode(f)==data,f.protocolName==domain,
              ["ticket","hello","challenge","ack","receipt"].contains(f.kind),
              DiagnosticBinding.matches(f.attemptID,"^[a-f0-9]{32}$"),
              DiagnosticBinding.matches(f.clientNonce,"^[a-f0-9]{32}$"),
              f.expiresAt>0,f.expiresAt<9_007_199_254_740_991,
              let sig=Data(base64Encoded:f.signature),sig.count==64,
              sig.base64EncodedString()==f.signature else {throw DiagnosticError.invalid}
        _ = try DiagnosticBinding(browser:f.binding.browser,extensionID:f.binding.extensionID,
            appFingerprint:f.binding.appFingerprint,extensionFingerprint:f.binding.extensionFingerprint,
            deployment:f.binding.deployment,configuration:f.binding.configuration)
        return f
    }
    func bytes()->Data {
        Data([Self.domain,kind,binding.browser,binding.extensionID,binding.appFingerprint,
              binding.extensionFingerprint,binding.deployment,binding.configuration,attemptID,clientNonce,String(expiresAt)].joined(separator:"\n").utf8)
    }
    public func verify(_ key:P256.Signing.PublicKey,now:Int64)throws {
        guard expiresAt>now,expiresAt-now<=30_000 else {throw DiagnosticError.expired}
        guard let data=Data(base64Encoded:signature),
              let sig=try? P256.Signing.ECDSASignature(rawRepresentation:data),
              key.isValidSignature(sig,for:bytes()) else {throw DiagnosticError.invalid}
    }
    public static func sign(kind:String,binding:DiagnosticBinding,attemptID:String,clientNonce:String,expiresAt:Int64,key:P256.Signing.PrivateKey)throws->Self {
        let f=Self(protocolName:domain,kind:kind,binding:binding,attemptID:attemptID,clientNonce:clientNonce,expiresAt:expiresAt,signature:"")
        return Self(protocolName:domain,kind:kind,binding:binding,attemptID:attemptID,clientNonce:clientNonce,expiresAt:expiresAt,
                    signature:try key.signature(for:f.bytes()).rawRepresentation.base64EncodedString())
    }
    public func sameAttempt(as other:Self)->Bool {
        binding==other.binding && attemptID==other.attemptID && expiresAt==other.expiresAt
    }
    public static var milliseconds:Int64 {Int64(Date().timeIntervalSince1970*1000)}
}

/// One explicitly armed attempt. No persistence, capture provider or validation API.
public final class DiagnosticAttempt {
    public let ticket:DiagnosticFrame
    private let appKey:P256.Signing.PrivateKey,extensionKey:P256.Signing.PublicKey
    private let lock=NSLock(), wall:()->Int64, monotonic:()->UInt64, until:UInt64
    private var phase=0,nonce:String?
    public init(binding:DiagnosticBinding,appKey:P256.Signing.PrivateKey,extensionKey:P256.Signing.PublicKey,
                wall:@escaping()->Int64={DiagnosticFrame.milliseconds},
                monotonic:@escaping()->UInt64={DispatchTime.now().uptimeNanoseconds})throws {
        guard DiagnosticBinding.digest(appKey.publicKey.x963Representation)==binding.appFingerprint,
              DiagnosticBinding.extensionDigest(browser:binding.browser,extensionID:binding.extensionID,key:extensionKey.x963Representation)==binding.extensionFingerprint else {throw DiagnosticError.invalid}
        self.appKey=appKey;self.extensionKey=extensionKey;self.wall=wall;self.monotonic=monotonic
        until=monotonic()+30_000_000_000
        ticket=try DiagnosticFrame.sign(kind:"ticket",binding:binding,attemptID:UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(),
            clientNonce:String(repeating:"0",count:32),expiresAt:wall()+30_000,key:appKey)
    }
    public func cancel(){lock.lock();phase=3;lock.unlock()}
    public var acknowledged:Bool {lock.lock();defer{lock.unlock()};return phase==2}
    public func receive(_ data:Data)throws->Data {
        lock.lock();defer{lock.unlock()}
        do {
            guard phase<2,monotonic()<until else {throw DiagnosticError.closed}
            let f=try DiagnosticFrame.decode(data)
            try f.verify(extensionKey,now:wall())
            guard f.sameAttempt(as:ticket),f.clientNonce != ticket.clientNonce else {throw DiagnosticError.invalid}
            let reply:String
            if phase==0 {
                guard f.kind=="hello" else {throw DiagnosticError.invalid}
                nonce=f.clientNonce;phase=1;reply="challenge"
            } else {
                guard f.kind=="ack",f.clientNonce==nonce else {throw DiagnosticError.invalid}
                phase=2;reply="receipt"
            }
            let signed=try DiagnosticFrame.sign(kind:reply,binding:ticket.binding,attemptID:ticket.attemptID,
                clientNonce:f.clientNonce,expiresAt:ticket.expiresAt,key:appKey)
            guard monotonic()<until,ticket.expiresAt>wall() else {throw DiagnosticError.expired}
            return try DiagnosticFrame.encode(signed)
        } catch {phase=3;throw error}
    }
}
