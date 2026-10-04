import Foundation
@main struct ReadinessChecks {
    static func main() throws {
        var count = 0
        func check(_ value: Bool, _ label: String) { precondition(value,label);count += 1;print("PASS " + label) }
        func facts() -> ChromePermissionReadiness.Facts {
            .init(sessionStatus: 0, sessionAttributes: 0x0010, signingInfoRead: true,
                  entitlementPresent: true, entitlementBooleanTrue: true, runtime: true,
                  usagePresent: true, bundleExpected: true, executableExpected: true,
                  appExists: true, appPolicy: 0, appRunning: true, releaseEnabled: true,
                  automationStatus: -1743)
        }
        let complete = ChromePermissionReadiness.fields(facts())
        for key in ["permissionRequestIssued","promptEligibilityVerified","responsibleApplicationVerified","typingProofGranted","inputPosted","storeOpened","captureStarted"] {
            check(complete[key] as? Bool == false,key + " remains false even with positive caller metadata")
        }
        check(complete["passiveAutomationOSStatus"] as? Int32 == -1743,"exact denial preserved without identifying its cause")
        check(complete["callerHasGraphicAccess"] as? Bool == true,"graphics availability measured")
        check(complete["callerIsRemoteSession"] as? Bool == false,"remote flag not inferred from caller route")
        var absent=facts();absent.entitlementPresent=false;absent.entitlementBooleanTrue=false
        let missing=ChromePermissionReadiness.fields(absent)
        check(missing["selfSigningInfoReadSucceeded"] as? Bool == true && missing["appleEventsEntitlementPresent"] as? Bool == false,"absent entitlement is known missing rather than an unreadable signature")
        var unknown=facts();unknown.sessionStatus = -60502;unknown.signingInfoRead=false;unknown.appExists=false
        let failed=ChromePermissionReadiness.fields(unknown)
        for key in ["callerHasGraphicAccess","callerIsRemoteSession","callerIsRootSession","appleEventsEntitlementPresent","appleEventsEntitlementBooleanTrue","selfHardenedRuntime","nsAppActivationPolicy","nsAppIsRunning"] {
            check(failed[key] == nil,"failed read omits " + key)
        }
        check(failed["securitySessionReadOSStatus"] as? Int32 == -60502,"session failure retained")
        var remote=facts();remote.sessionAttributes=0x1001
        let rf=ChromePermissionReadiness.fields(remote)
        check(rf["callerHasGraphicAccess"] as? Bool == false && rf["callerIsRemoteSession"] as? Bool == true && rf["callerIsRootSession"] as? Bool == true,"session bits independent")
        for status:Int32 in [0,-1744,-1743,-600,-50] {
            var f=facts();f.automationStatus=status
            let output=ChromePermissionReadiness.fields(f)
            check(output["passiveAutomationOSStatus"] as? Int32 == status && output["typingProofGranted"] as? Bool == false,"status never grants capture")
        }
        let allowed:Set<String> = ["phase","inspectionOnly","securitySessionReadOSStatus","securitySessionReadSucceeded","selfSigningInfoReadSucceeded","appleEventsUsagePresent","ownBundleExpected","ownExecutableExpected","nsAppExists","releaseEnabled","passiveAutomationOSStatus","permissionRequestIssued","promptEligibilityVerified","responsibleApplicationVerified","typingProofGranted","inputPosted","storeOpened","captureStarted","callerHasGraphicAccess","callerIsRemoteSession","callerIsRootSession","appleEventsEntitlementPresent","appleEventsEntitlementBooleanTrue","selfHardenedRuntime","nsAppActivationPolicy","nsAppIsRunning"]
        check(Set(complete.keys)==allowed,"closed metadata schema contains no session/PID/path/URL/content")
        check(JSONSerialization.isValidJSONObject(complete) && JSONSerialization.isValidJSONObject(failed),"known and unknown metadata JSON encode")
        print("\(count) pure Chrome readiness controls passed; collector never called.")
    }
}
