#if DAYDREAM_QA_HARNESS && DAYDREAM_OWNER_TYPING
import AppKit
import Foundation
import Security

/// Caller metadata only. No request, Apple event, target inspection, app
/// activation, capture or store. A positive snapshot is never consent.
enum ChromePermissionReadiness {
    struct Facts {
        var sessionStatus: Int32
        var sessionAttributes: UInt32
        var signingInfoRead: Bool
        var entitlementPresent: Bool
        var entitlementBooleanTrue: Bool
        var runtime: Bool
        var usagePresent: Bool
        var bundleExpected: Bool
        var executableExpected: Bool
        var appExists: Bool
        var appPolicy: Int?
        var appRunning: Bool?
        var releaseEnabled: Bool
        var automationStatus: Int32
    }
    static func fields(_ f: Facts) -> [String: Any] {
        var out: [String: Any] = [
            "phase": "permission-readiness", "inspectionOnly": true,
            "securitySessionReadOSStatus": f.sessionStatus,
            "securitySessionReadSucceeded": f.sessionStatus == 0,
            "selfSigningInfoReadSucceeded": f.signingInfoRead,
            "appleEventsUsagePresent": f.usagePresent,
            "ownBundleExpected": f.bundleExpected,
            "ownExecutableExpected": f.executableExpected,
            "nsAppExists": f.appExists,
            "releaseEnabled": f.releaseEnabled,
            "passiveAutomationOSStatus": f.automationStatus,
            "permissionRequestIssued": false, "promptEligibilityVerified": false,
            "responsibleApplicationVerified": false, "typingProofGranted": false,
            "inputPosted": false, "storeOpened": false, "captureStarted": false
        ]
        // Failed observations stay unknown; never manufacture negative facts.
        if f.sessionStatus == 0 {
            out["callerHasGraphicAccess"] = f.sessionAttributes & 0x0010 != 0
            out["callerIsRemoteSession"] = f.sessionAttributes & 0x1000 != 0
            out["callerIsRootSession"] = f.sessionAttributes & 0x0001 != 0
        }
        if f.signingInfoRead {
            out["appleEventsEntitlementPresent"] = f.entitlementPresent
            out["appleEventsEntitlementBooleanTrue"] = f.entitlementBooleanTrue
            out["selfHardenedRuntime"] = f.runtime
        }
        if f.appExists {
            if let policy = f.appPolicy { out["nsAppActivationPolicy"] = policy }
            if let running = f.appRunning { out["nsAppIsRunning"] = running }
        }
        return out
    }
    @MainActor static func collect(releaseEnabled: Bool, automationStatus: Int32) -> [String: Any] {
        var session: SecuritySessionId = 0
        var attributes: SessionAttributeBits = []
        let sessionStatus = SessionGetInfo(callerSecuritySession, &session, &attributes)
        // Never serialize the session ID or paths from signing information.
        var code: SecCode?, staticCode: SecStaticCode?, information: CFDictionary?
        var info: [String: Any]?
        if SecCodeCopySelf([], &code) == errSecSuccess, let code,
           SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
           SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess {
            info = information as? [String: Any]
        }
        let entitlementInfo = info?[kSecCodeInfoEntitlementsDict as String]
        let entitlements = entitlementInfo as? [String: Any]
        let entitlement = entitlements?["com.apple.security.automation.apple-events"]
        let flags = info?[kSecCodeInfoFlags as String] as? UInt32
        let entitlementTrue = entitlement.map {
            CFGetTypeID($0 as CFTypeRef) == CFBooleanGetTypeID() && ($0 as? Bool) == true
        } ?? false
        let usage = Bundle.main.object(forInfoDictionaryKey: "NSAppleEventsUsageDescription") as? String
        let application = NSApp // Observe only; never create NSApplication.shared.
        return fields(Facts(sessionStatus: sessionStatus, sessionAttributes: attributes.rawValue,
                            signingInfoRead: info != nil && flags != nil && (entitlementInfo == nil || entitlements != nil),
                            entitlementPresent: entitlement != nil, entitlementBooleanTrue: entitlementTrue,
                            runtime: flags.map { $0 & 0x10000 /* Security/CSCommon.h: kSecCodeSignatureRuntime */ != 0 } ?? false,
                            usagePresent: usage.map { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? false,
                            bundleExpected: Bundle.main.bundleIdentifier == "com.getnorthlight.daydream",
                            executableExpected: Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "MacMem",
                            appExists: application != nil, appPolicy: application?.activationPolicy().rawValue,
                            appRunning: application?.isRunning, releaseEnabled: releaseEnabled,
                            automationStatus: automationStatus))
    }
}
#endif
