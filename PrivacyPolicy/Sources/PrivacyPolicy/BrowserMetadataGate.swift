import Foundation

/// Authenticated browser-owned metadata. Not a FocusProof or an AX witness.
/// Construct only after signature verification on the native capture executor.
public struct BrowserMetadataProof {
    public var bundle="", origin="", role="", sessionID=""
    public var generation:UInt64=0, policyVersion:UInt64=0, checkedAt:UInt64=0
    public var authenticated=false, normalWindow=false, normalTab=false, noneditable=false
    public var secureInput:VerifiedFlag = .unknown
    public var windowID = -1, tabID = -1, frameID = -1, navigationGeneration=0, focusGeneration=0
    public var documentID="", focusID=""
    public init() {}
}
public enum BrowserMetadataGate {
    public static let bundles:Set<String>=["com.google.Chrome","com.apple.Safari"]
    public static func preflight(bundle:String,secureInput:VerifiedFlag,policy:CapturePolicy)->Bool {
        bundles.contains(bundle) && secureInput == .no && !policy.excludedApps.contains(bundle)
    }
    public static func originAllowed(_ origin:String,policy:CapturePolicy)->Bool {
        guard origin.utf8.count<=256,let u=URLComponents(string:origin),["http","https"].contains(u.scheme),
              let raw=u.host?.lowercased(),!raw.isEmpty,u.user==nil,u.password==nil,u.query==nil,u.fragment==nil,
              ["","/"].contains(u.path) else {return false}
        let host=raw.trimmingCharacters(in:CharacterSet(charactersIn:"."))
        guard !policy.excludedDomains.union(CaptureGate.sensitiveDomains).contains(where:{
            let d=$0.trimmingCharacters(in:.whitespacesAndNewlines).lowercased().trimmingCharacters(in:CharacterSet(charactersIn:"."))
            return !d.isEmpty && (host==d || host.hasSuffix("."+d))
        }),!["login","signin","oauth","password","wallet","bank","token","secret"].contains(where:host.contains),
        TextClassifier.sensitiveReason(host)==nil else {return false}
        return true
    }
    public static func allows(_ p:BrowserMetadataProof,policy:CapturePolicy,generation:UInt64,now:UInt64)->Bool {
        preflight(bundle:p.bundle,secureInput:p.secureInput,policy:policy) && p.authenticated &&
        p.normalWindow && p.normalTab && p.noneditable && p.generation==generation && generation>0 &&
        p.policyVersion==policy.version && now>=p.checkedAt && now-p.checkedAt<=500_000_000 &&
        p.windowID>=0 && p.tabID>=0 && p.frameID==0 && p.navigationGeneration>0 && p.focusGeneration>0 &&
        UUID(uuidString:p.documentID) != nil && UUID(uuidString:p.focusID) != nil &&
        p.sessionID.range(of:"^[a-f0-9]{32}$",options:.regularExpression) != nil &&
        ["button","link","document"].contains(p.role) && originAllowed(p.origin,policy:policy)
    }
}
