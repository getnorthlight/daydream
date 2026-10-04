import Foundation
import CryptoKit
import Darwin

/// Public-only read of EXISTING reviewed configuration. Never opens Keychain,
/// enrollment locks or a validation file. The app supplies the previously pinned public key.
public struct DiagnosticConfiguration {
    public let binding:DiagnosticBinding,appPublicKey:P256.Signing.PublicKey,extensionPublicKey:P256.Signing.PublicKey,directory:URL
    private struct Signed:Codable {let payload:Data,signature:Data}
    private struct Config:Codable {
        let version:Int,browser:String,extensionID:String,registrationFingerprint:String
        let relayDirectory:String,deployment:String,appFingerprint:String
    }
    private struct Registration:Codable {let browser:String,extensionID:String,publicKey:Data,fingerprint:String}
    static func privateDirectory(_ url:URL)throws {
        var info=stat()
        guard let physical=realpath(url.path,nil) else {throw DiagnosticError.unavailable}
        defer{free(physical)}
        guard url.isFileURL,url.path==String(cString:physical),
              lstat(url.path,&info)==0,info.st_mode&S_IFMT==S_IFDIR,
              info.st_uid==geteuid(),info.st_mode&0o077==0 else {throw DiagnosticError.unavailable}
    }
    private static func read(_ url:URL,max:Int)throws->Data {
        let fd=open(url.path,O_RDONLY|O_NOFOLLOW);guard fd>=0 else {throw DiagnosticError.unavailable};defer{Darwin.close(fd)}
        var s=stat();guard fstat(fd,&s)==0,s.st_mode&S_IFMT==S_IFREG,s.st_uid==geteuid(),s.st_mode&0o077==0,
            s.st_size>0,s.st_size<=max else {throw DiagnosticError.invalid}
        let data=try FileHandle(fileDescriptor:fd,closeOnDealloc:false).read(upToCount:max+1) ?? Data()
        guard data.count<=max else {throw DiagnosticError.invalid};return data
    }
    public static func load(setupDirectory:URL,diagnosticDirectory:URL,browser:String,extensionID:String,
                            deployment:String,trustedAppPublicKey:Data)throws->Self {
        guard ["chrome","safari"].contains(browser) else {throw DiagnosticError.invalid}
        try privateDirectory(setupDirectory);try privateDirectory(diagnosticDirectory)
        let app=try P256.Signing.PublicKey(x963Representation:trustedAppPublicKey)
        let raw=try read(setupDirectory.appendingPathComponent(browser+"-configuration.json"),max:32768)
        let signed=try JSONDecoder().decode(Signed.self,from:raw)
        guard signed.payload.count<=20000,
              app.isValidSignature(try P256.Signing.ECDSASignature(rawRepresentation:signed.signature),
                for:Data("daydream-reviewed-browser-setup-v1\n".utf8)+signed.payload) else {throw DiagnosticError.invalid}
        let c=try JSONDecoder().decode(Config.self,from:signed.payload)
        guard c.version==1,c.browser==browser,c.extensionID==extensionID,c.deployment==deployment,
            c.appFingerprint==DiagnosticBinding.digest(trustedAppPublicKey) else {throw DiagnosticError.invalid}
        let rows=try JSONDecoder().decode([Registration].self,from:read(setupDirectory.appendingPathComponent("registrations.json"),max:16384))
        guard rows.count<=2,Set(rows.map{$0.browser}).count==rows.count,
              let r=rows.first(where:{$0.browser==browser}),r.extensionID==extensionID,
              r.fingerprint==c.registrationFingerprint,r.fingerprint==DiagnosticBinding.extensionDigest(browser:browser,extensionID:extensionID,key:r.publicKey) else {throw DiagnosticError.invalid}
        let ext=try P256.Signing.PublicKey(x963Representation:r.publicKey)
        let binding=try DiagnosticBinding(browser:browser,extensionID:extensionID,appFingerprint:c.appFingerprint,
            extensionFingerprint:r.fingerprint,deployment:deployment,
            configuration:DiagnosticBinding.digest(signed.payload+Data(("\n"+diagnosticDirectory.path).utf8)))
        return Self(binding:binding,appPublicKey:app,extensionPublicKey:ext,directory:diagnosticDirectory)
    }
}
