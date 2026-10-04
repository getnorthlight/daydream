import Foundation
import CryptoKit
import Darwin

public enum MetadataSetupError:Error {case unavailable,invalid,unreviewed,expired,changedConfiguration}
public struct MetadataReviewedConfiguration:Codable,Equatable {
    public let version:Int,browser:MetadataBrowser,extensionID:String,registrationFingerprint:String
    public let relayDirectory:String,deployment:String,appFingerprint:String
    public init(registration:MetadataRegistration,relayDirectory:URL,deployment:String,appKey:P256.Signing.PrivateKey)throws {
        try MetadataLocalTransport.directory(relayDirectory)
        guard Self.hash(deployment) else {throw MetadataSetupError.invalid}
        self.version=1;self.browser=registration.browser;self.extensionID=registration.extensionID
        self.registrationFingerprint=registration.fingerprint;self.relayDirectory=relayDirectory.path
        self.deployment=deployment;self.appFingerprint=MetadataProductionSetup.digest(appKey.publicKey.x963Representation)
    }
    static func hash(_ value:String)->Bool {value.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil}
}
private struct MetadataSignedRecord:Codable {let payload:Data,signature:Data}
public struct MetadataValidationRecord:Codable {
    public let version:Int,configurationDigest:String,request:Data,response:Data
    public let reviewedChecks:[String],reviewedAt:Date,expiresAt:Date
    public let reviewBasis:String
}
public struct MetadataResolvedProvider {
    public let pins:MetadataPins,directory:URL,configuration:MetadataReviewedConfiguration
    public let integrationValidated:Bool,physicalDeviceValidated:Bool,status:String
}

/// One native-owned setup store. The caller chooses this exact private directory
/// and Keychain service. Loading never creates keys or accepts a first-use pin.
public final class MetadataProductionSetup {
    public static let requiredChecks:Set<String>=["normal_active_page","background_no_capture","private_no_capture","secure_unknown_no_capture","navigation_focus_race","permission_revocation","disconnect_restart","canonical_origin_only"]
    private let directory:URL,key:P256.Signing.PrivateKey,registrations:MetadataRegistrationFile
    public init(directory:URL,appKey:P256.Signing.PrivateKey)throws {
        try MetadataLocalTransport.directory(directory);self.directory=directory;key=appKey
        registrations=try MetadataRegistrationFile(directory:directory)
    }
    public static func existing(directory:URL,keychainService:String)throws->MetadataProductionSetup {
        try Self(directory:directory,appKey:MetadataAppKeychain.loadOrCreate(service:keychainService,allowCreate:false))
    }
    public static func digest(_ data:Data)->String {SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined()}
    private func encode<T:Encodable>(_ value:T)throws->Data {let e=JSONEncoder();e.outputFormatting=[.sortedKeys];return try e.encode(value)}
    private func bytes(_ payload:Data)->Data {Data("daydream-reviewed-browser-setup-v1\n".utf8)+payload}
    private func load(_ name:String)throws->Data {
        let fd=open(directory.appendingPathComponent(name).path,O_RDONLY|O_NOFOLLOW)
        guard fd>=0 else {throw MetadataSetupError.unavailable};defer{Darwin.close(fd)}
        var s=stat();guard fstat(fd,&s)==0,s.st_uid==geteuid(),s.st_mode&S_IFMT==S_IFREG,s.st_mode&0o077==0,s.st_size>0,s.st_size<=32_768 else {throw MetadataSetupError.invalid}
        let raw=try FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:32_769) ?? Data()
        let record=try JSONDecoder().decode(MetadataSignedRecord.self,from:raw)
        let signature=try P256.Signing.ECDSASignature(rawRepresentation:record.signature)
        guard record.payload.count<=20_000,key.publicKey.isValidSignature(signature,for:bytes(record.payload)) else {throw MetadataSetupError.invalid}
        return record.payload
    }
    private func save<T:Encodable>(_ value:T,name:String,replace:Bool=true)throws {
        let payload=try encode(value),record=try encode(MetadataSignedRecord(payload:payload,signature:key.signature(for:bytes(payload)).rawRepresentation))
        guard record.count<=32_768 else {throw MetadataSetupError.invalid}
        let temporary=directory.appendingPathComponent(".setup-"+UUID().uuidString),target=directory.appendingPathComponent(name)
        let fd=open(temporary.path,O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW,0o600)
        guard fd>=0 else {throw MetadataSetupError.unavailable}
        let handle=FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        do {
            try handle.write(contentsOf:record);try handle.synchronize();try handle.close()
            if replace {guard rename(temporary.path,target.path)==0 else {throw MetadataSetupError.unavailable}}
            else {
                guard link(temporary.path,target.path)==0 else {throw MetadataSetupError.changedConfiguration}
                try FileManager.default.removeItem(at:temporary)
            }
        }
        catch {try? handle.close();try? FileManager.default.removeItem(at:temporary);throw error}
    }
    /// Called after MetadataEnrollment.approve, not by an incoming message.
    /// A changed configuration is rejected; explicit separate reset/review is needed.
    public func reviewConfiguration(registration:MetadataRegistration,relayDirectory:URL,deployment:String,nativeHumanConfirmed:Bool)throws->MetadataReviewedConfiguration {
        guard nativeHumanConfirmed,try registrations.load(browser:registration.browser,extensionID:registration.extensionID)==registration else {throw MetadataSetupError.unreviewed}
        let config=try MetadataReviewedConfiguration(registration:registration,relayDirectory:relayDirectory,deployment:deployment,appKey:key)
        let name=registration.browser.rawValue+"-configuration.json"
        if FileManager.default.fileExists(atPath:directory.appendingPathComponent(name).path) {
            guard try JSONDecoder().decode(MetadataReviewedConfiguration.self,from:load(name))==config else {throw MetadataSetupError.changedConfiguration}
        } else {try save(config,name:name,replace:false)}
        return config
    }
    public func resolve(browser:MetadataBrowser,expectedDeployment:String,now:Date=Date())throws->MetadataResolvedProvider {
        let raw=try load(browser.rawValue+"-configuration.json"),c=try JSONDecoder().decode(MetadataReviewedConfiguration.self,from:raw)
        guard c.version==1,c.browser==browser,c.deployment==expectedDeployment,MetadataReviewedConfiguration.hash(expectedDeployment),
              c.appFingerprint==Self.digest(key.publicKey.x963Representation),
              let registration=try registrations.load(browser:browser,extensionID:c.extensionID),registration.fingerprint==c.registrationFingerprint else {throw MetadataSetupError.changedConfiguration}
        let relay=URL(fileURLWithPath:c.relayDirectory,isDirectory:true);try MetadataLocalTransport.directory(relay)
        let pins=MetadataPins(extensionID:c.extensionID,extensionKey:try P256.Signing.PublicKey(x963Representation:registration.publicKey),appKey:key,browser:browser)
        var validated=false,status="physical_validation_required"
        do {
            let v=try JSONDecoder().decode(MetadataValidationRecord.self,from:load(browser.rawValue+"-validation.json"))
            guard v.version==1,v.configurationDigest==Self.digest(raw),v.reviewBasis=="native_operator_reviewed_device",
                  Set(v.reviewedChecks)==Self.requiredChecks,v.reviewedChecks.count==Self.requiredChecks.count,
                  v.reviewedAt<=now,now<v.expiresAt,v.expiresAt.timeIntervalSince(v.reviewedAt)<=30*86400,
                  MetadataDiagnosticSession.verify(request:v.request,response:v.response,pins:pins,deployment:c.deployment,now:v.reviewedAt) else {throw MetadataSetupError.invalid}
            validated=true;status="reviewed_device_validation"
        } catch MetadataSetupError.unavailable {} catch {status="validation_invalid_or_expired"}
        return MetadataResolvedProvider(pins:pins,directory:relay,configuration:c,integrationValidated:validated,physicalDeviceValidated:validated,status:status)
    }
    /// Human confirmation is a native setup action, never a JSON/wire field.
    /// The signed no-content ack proves the channel only. The listed physical
    /// checks must actually have been performed and reviewed before this call.
    public func recordValidation(browser:MetadataBrowser,expectedDeployment:String,request:Data,response:Data,reviewedChecks:Set<String>,nativeHumanConfirmed:Bool,now:Date=Date())throws {
        let resolved=try resolve(browser:browser,expectedDeployment:expectedDeployment,now:now)
        guard nativeHumanConfirmed,reviewedChecks==Self.requiredChecks,
              MetadataDiagnosticSession.verify(request:request,response:response,pins:resolved.pins,deployment:expectedDeployment,now:now) else {throw MetadataSetupError.unreviewed}
        let raw=try load(browser.rawValue+"-configuration.json")
        try save(MetadataValidationRecord(version:1,configurationDigest:Self.digest(raw),request:request,response:response,
            reviewedChecks:reviewedChecks.sorted(),reviewedAt:now,expiresAt:now.addingTimeInterval(30*86400),reviewBasis:"native_operator_reviewed_device"),name:browser.rawValue+"-validation.json")
    }
}

/// Credential/content-free connection diagnostic. This never issues a Probe,
/// examines a tab, or enables metadata. Each request is tied to deployment/pins.
public final class MetadataDiagnosticSession {
    private let pins:MetadataPins,clientNonce:String,deployment:String
    private var requestBytes:Data?
    public init?(pins:MetadataPins,clientNonce:String,deployment:String) {
        guard SignedMetadataFrame.token(clientNonce),MetadataReviewedConfiguration.hash(deployment) else{return nil}
        self.pins=pins;self.clientNonce=clientNonce;self.deployment=deployment
    }
    public func request(now:Date=Date())throws->Data {
        guard requestBytes==nil else {throw MetadataSetupError.invalid}
        let payload=try JSONSerialization.data(withJSONObject:["kind":"diagnostic","nonce":UUID().uuidString.lowercased(),"deployment":deployment,"issuedAt":now.timeIntervalSince1970])
        let data=try SignedMetadataFrame.sign(payload:payload,extensionID:pins.extensionID,clientNonce:clientNonce,sessionID:UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased(),sequence:1,direction:"app-to-extension",key:pins.appKey,browser:pins.browser)
        requestBytes=data;return data
    }
    public func accept(_ response:Data,now:Date=Date())->Bool {
        guard let request=requestBytes else{return false};requestBytes=nil
        return Self.verify(request:request,response:response,pins:pins,deployment:deployment,now:now)
    }
    static func verify(request:Data,response:Data,pins:MetadataPins,deployment:String,now:Date)->Bool {
        guard let q=SignedMetadataFrame.decode(request),let a=SignedMetadataFrame.decode(response),
              q.browser==pins.browser,a.browser==q.browser,q.extensionID==pins.extensionID,a.extensionID==q.extensionID,
              a.clientNonce==q.clientNonce,a.sessionID==q.sessionID,a.sequence==q.sequence,q.sequence==1,
              let qb=q.verified(pins.appKey.publicKey,direction:"app-to-extension"),let ab=a.verified(pins.extensionKey,direction:"extension-to-app"),
              let p=try? JSONSerialization.jsonObject(with:qb) as? [String:Any],let result=try? JSONSerialization.jsonObject(with:ab) as? [String:Any],
              Set(p.keys)==["kind","nonce","deployment","issuedAt"],p["kind"] as? String=="diagnostic",p["deployment"] as? String==deployment,
              let nonce=p["nonce"] as? String,UUID(uuidString:nonce) != nil,let at=p["issuedAt"] as? Double,
              now.timeIntervalSince1970>=at,now.timeIntervalSince1970-at<=120,
              Set(result.keys)==["kind","nonce","deployment","issuedAt","runtimeID","contentRead"],
              result["kind"] as? String=="diagnostic_ack",result["nonce"] as? String==nonce,result["deployment"] as? String==deployment,
              result["issuedAt"] as? Double==at,result["runtimeID"] as? String==pins.extensionID,result["contentRead"] as? Bool==false else{return false}
        return true
    }
}
