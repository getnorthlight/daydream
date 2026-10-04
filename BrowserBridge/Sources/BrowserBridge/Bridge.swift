import Foundation

public struct BridgePolicy {
    public var revision = 1
    public var metadataConsent = false
    public var integrationValidated = false
    public var physicalDeviceValidated = false
    public var allowedOrigins: Set<String> = []
    public var ordinaryMetadata = false
    public var excludedDomains: Set<String> = []
    public init() {}
    public var enabled: Bool { metadataConsent && integrationValidated && physicalDeviceValidated }
    /// Master recording consent is the metadata consent. Typing is separate
    /// and this module has no text-enabling path.
    public static func masterRecording(_ recording:Bool, integrationValidated:Bool, physicalDeviceValidated:Bool,
                                       revision:Int, excludedDomains:Set<String>) -> BridgePolicy {
        var p=BridgePolicy();p.metadataConsent=recording;p.ordinaryMetadata=true
        p.integrationValidated=integrationValidated;p.physicalDeviceValidated=physicalDeviceValidated
        p.revision=revision;p.excludedDomains=excludedDomains;return p
    }
}

/// Construct only from the trusted native launch/IPC adapter, NEVER from JSON.
/// argv origin alone is insufficient: the app must validate its signed helper
/// and browser/channel identity. The standalone host supplies no verified peer.
public struct NativePeer {
    public var extensionID: String
    public var callerOrigin: String
    public var browserBundle: String
    public var verifiedLaunchIdentity: Bool
    public init(extensionID:String, callerOrigin:String, browserBundle:String, verifiedLaunchIdentity:Bool) {
        self.extensionID=extensionID; self.callerOrigin=callerOrigin
        self.browserBundle=browserBundle; self.verifiedLaunchIdentity=verifiedLaunchIdentity
    }
}

/// Independent native state checked BEFORE asking the extension to inspect DOM.
public struct NativePreflight {
    public var frontmostChrome=false, normalWindow=false, secureInputOff=false, permissionPresent=false
    public var checkedAt:UInt64=0
    public init() {}
    func valid(_ now:UInt64)->Bool {
        frontmostChrome && normalWindow && secureInputOff && permissionPresent &&
        now >= checkedAt && now-checkedAt <= 1_000_000_000
    }
}

/// No API currently establishes Chrome extension windowID == AX/AppleEvents ID.
/// Both mappings must be independently implemented/tested by the native owner.
public struct NativeWitness {
    public var preflight=NativePreflight()
    public var nativeWindowID="", nativeFocusID="", role=""
    public var windowMappingVerified=false, focusMappingVerified=false
    public var windowID=0, tabID=0, frameID=0, documentID="", focusID=""
    public init() {}
}

public struct Probe: Encodable {
    public let version=1, kind="probe", textEnabled=false
    public let nonce:String, policyRevision:Int, allowedOrigins:[String]
    public let ordinaryMetadata:Bool?, excludedDomains:[String]?
    public init(nonce:String,policyRevision:Int,allowedOrigins:[String],ordinaryMetadata:Bool?=nil,excludedDomains:[String]?=nil) {
        self.nonce=nonce;self.policyRevision=policyRevision;self.allowedOrigins=allowedOrigins
        self.ordinaryMetadata=ordinaryMetadata;self.excludedDomains=excludedDomains
    }
}

public struct BrowserObservation: Decodable, Equatable {
    public let version:Int, kind:String, nonce:String, policyRevision:Int
    public let windowMode:String, tabMode:String, windowID:Int, tabID:Int, frameID:Int
    public let documentID:String, navigationGeneration:Int, focusID:String, focusGeneration:Int
    public let role:String, safety:String, origin:String, textEnabled:Bool
    public static let keys:Set<String> = ["version","kind","nonce","policyRevision","windowMode","tabMode","windowID","tabID","frameID","documentID","navigationGeneration","focusID","focusGeneration","role","safety","origin","textEnabled"]
    public static func decode(_ data:Data)->BrowserObservation? {
        guard data.count <= 4096, let json=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
              Set(json.keys)==keys else {return nil}
        return try? JSONDecoder().decode(Self.self,from:data)
    }
}

public struct VerifiedBrowserEvent: Equatable {
    public let kind:String // browser.observed or browser.tab_visited, never sent/read
    public let bundle:String, origin:String, windowID:Int, tabID:Int, documentID:String
    public let frameID:Int, navigationGeneration:Int, focusID:String, focusGeneration:Int
    public let role:String, policyRevision:Int, sessionID:String
    public let checkedAt:UInt64, continuousNanoseconds:UInt64
    // Deliberately no title, URL path/query/fragment, candidate text or receipt.
}

/// Call exclusively on the app's capture serial executor. Not a service,
/// permission grant, global input tap, persistence layer or privacy-policy fork.
public final class BrowserReceiver {
    public private(set) var status="disconnected"
    public let textEnabled=false
    private let configuredExtensionID:String
    private var peer:NativePeer?
    private var sessionID=""
    private var pending:(nonce:String, at:UInt64, policy:BridgePolicy)?
    private var last:(identity:String, first:UInt64, sampled:UInt64, visited:Bool)?
    private var lastRequest:UInt64?
    private var latestGeneration=0
    public init(extensionID:String) { configuredExtensionID=extensionID }
    public func connect(_ candidate:NativePeer)->Bool {
        disconnect()
        guard candidate.extensionID.range(of:"^[a-p]{32}$",options:.regularExpression) != nil,
              candidate.extensionID == configuredExtensionID,
              candidate.callerOrigin == "chrome-extension://\(configuredExtensionID)/",
              candidate.browserBundle == "com.google.Chrome", candidate.verifiedLaunchIdentity else {
            status="invalid_sender_or_unsupported_browser"; return false
        }
        peer=candidate; sessionID=UUID().uuidString; status="awaiting_policy"; return true
    }
    public func invalidate() { pending=nil; last=nil; status="invalidated" }
    public func disconnect() { invalidate(); peer=nil; sessionID=""; latestGeneration=0; lastRequest=nil; status="disconnected" }
    public func request(policy:BridgePolicy, preflight:NativePreflight, now:UInt64)->Probe? {
        guard peer != nil, policy.enabled, preflight.valid(now), policy.revision>0,
              !policy.allowedOrigins.isEmpty, policy.allowedOrigins.count<=32,
              policy.allowedOrigins.allSatisfy(Self.originOnly) else { invalidate(); status="policy_or_native_proof_missing"; return nil }
        guard pending == nil, lastRequest.map({now >= $0 && now-$0 >= 100_000_000}) ?? true else {
            invalidate(); status="probe_rate_or_overlap"; return nil
        }
        let nonce=UUID().uuidString.replacingOccurrences(of:"-",with:"").lowercased()
        pending=(nonce,now,policy); lastRequest=now; status="awaiting_observation"
        return Probe(nonce:nonce,policyRevision:policy.revision,allowedOrigins:policy.allowedOrigins.sorted())
    }
    public func receive(_ data:Data, policy:BridgePolicy, witness:NativeWitness, now:UInt64,
                        privacyAllowsMetadata:(BrowserObservation)->Bool)->VerifiedBrowserEvent? {
        let challenge=pending; pending=nil // single use even if the payload is invalid
        guard peer != nil, let challenge, now >= challenge.at, now-challenge.at<=1_000_000_000,
              policy.enabled, policy.revision==challenge.policy.revision,
              policy.allowedOrigins==challenge.policy.allowedOrigins,
              let e=BrowserObservation.decode(data), e.version==1, e.kind=="observation", !e.textEnabled,
              e.nonce==challenge.nonce, e.policyRevision==policy.revision,
              e.windowMode=="normal",e.tabMode=="normal",e.windowID>=0,e.tabID>=0,e.frameID==0,
              UUID(uuidString:e.documentID) != nil, UUID(uuidString:e.focusID) != nil,
              e.navigationGeneration>0,e.navigationGeneration>=latestGeneration,e.focusGeneration>0,
              ["button","link"].contains(e.role),e.safety=="noneditable",
              Self.originOnly(e.origin),policy.allowedOrigins.contains(e.origin),
              witness.preflight.valid(now), witness.windowMappingVerified, witness.focusMappingVerified,
              !witness.nativeWindowID.isEmpty, !witness.nativeFocusID.isEmpty,
              witness.windowID==e.windowID,witness.tabID==e.tabID,witness.frameID==e.frameID,
              witness.documentID==e.documentID,witness.focusID==e.focusID,
              witness.role==(e.role=="button" ? "AXButton":"AXLink"),
              privacyAllowsMetadata(e) else {last=nil; status="observation_denied";return nil}
        latestGeneration=e.navigationGeneration
        let identity="\(e.windowID)/\(e.tabID)/\(e.documentID)/\(e.navigationGeneration)/\(e.focusID)/\(e.focusGeneration)/\(e.origin)/\(policy.revision)"
        if last?.identity != identity || now < (last?.sampled ?? now) || now-(last?.sampled ?? now)>1_000_000_000 {
            last=(identity,now,now,false)
        }
        let elapsed=now-last!.first, visited=elapsed>=10_000_000_000 && !last!.visited
        last=(identity,last!.first,now,last!.visited || visited);status="metadata_verified"
        return VerifiedBrowserEvent(kind:visited ? "browser.tab_visited":"browser.observed",bundle:"com.google.Chrome",origin:e.origin,
            windowID:e.windowID,tabID:e.tabID,documentID:e.documentID,frameID:e.frameID,navigationGeneration:e.navigationGeneration,
            focusID:e.focusID,focusGeneration:e.focusGeneration,role:e.role,policyRevision:policy.revision,sessionID:sessionID,
            checkedAt:now,continuousNanoseconds:elapsed)
    }
    public static func originOnly(_ raw:String)->Bool {
        guard raw.utf8.count<=256,let url=URLComponents(string:raw),["http","https"].contains(url.scheme ?? ""),
              let host=url.host,!host.isEmpty,url.user==nil,url.password==nil,url.query==nil,url.fragment==nil,url.path.isEmpty else {return false}
        return raw == "\(url.scheme!)://\(host)\(url.port.map { ":\($0)" } ?? "")"
    }
}
