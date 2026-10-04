import Foundation
import HistoryCore
import PrivacyPolicy

/// Metadata only. Never accepts candidate characters or calls a classifier.
/// This is a supplemental deny list, not universal banking/private-mode detection.
public enum PreCapturePrivacy {
    /// The capture gate's typing apps (the category table's allowed set):
    /// Notes and TextEdit in public builds.
    public static let supportedTypingApps:Set<String> = CaptureGate.nativeApps
    public static func websiteDenied(_ raw:String, settings:PrivacySettings) -> Bool {
        guard !raw.isEmpty else { return false }
        guard let url=URLComponents(string:raw), let host=url.host?.lowercased(),
              ["http","https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil else { return true }
        // One matching rule everywhere (BrowserSites.matches). A saved entry that
        // does not normalize keeps its old trimmed form, so no block is lost.
        // Every row read comes here: the lists are normalized once, not per row.
        if (fixedDomains + ownerDomains(settings.blockedDomains)).contains(where: { BrowserSites.matches(host:host,domain:$0) }) { return true }
        let metadata=(host+" "+url.path).removingPercentEncoding?.lowercased() ?? ""
        return ["bank","payment","checkout","password","login","log-in","signin","sign-in","oauth","authenticate","wallet"].contains(where:metadata.contains)
    }
    static func domainForm(_ entry:String) -> String {
        BrowserSites.normalizedDomain(entry) ?? entry.lowercased().trimmingCharacters(in:.whitespacesAndNewlines)
    }
    /// The app-wide sensitive sites and the Chrome page defaults, normalized once.
    static let fixedDomains:[String]=(PrivacySettings.sensitiveDomains + BrowserSiteList.pageDefaults).map(domainForm)
    private static let ownerLock=NSLock()
    private static var ownerMemo:(raw:[String],domains:[String])=([],[])
    /// The owner's saved sites, normalized once per change of the list.
    static func ownerDomains(_ raw:[String]) -> [String] {
        if raw.isEmpty { return [] }
        ownerLock.lock(); defer { ownerLock.unlock() }
        if ownerMemo.raw == raw { return ownerMemo.domains }
        let domains=raw.map(domainForm)
        ownerMemo=(raw,domains)
        return domains
    }
    public static func nativeTypingAllowed(bundle:String,role:String,url:String,secure:Bool,settings:PrivacySettings) -> Bool {
        guard settings.captureText, settings.typedConsentVersion == 1, !secure, supportedTypingApps.contains(bundle),
              !CaptureSession.excludedBrowsers.contains(bundle),
              ["AXTextField","AXTextArea"].contains(role),
              settings.policy.dropReason(bundleIdentifier:bundle,windowTitle:nil,urlDomain:url) == nil,
              !websiteDenied(url,settings:settings) else { return false }
        // Embedded web content has no verified normal/private/navigation proof.
        return url.isEmpty
    }
}

/// Common password managers: always private, never recorded, and not changeable in
/// Settings. The UI says "Common password managers are skipped. Add others in
/// Settings." because no list can be complete; the person excludes any other app
/// in Settings > Apps to remember.
///
/// Matching is exact (`ObservationPolicy` application rules), so every known
/// identifier of an app is listed, including App Store and older editions.
/// Listing an identifier that no app uses only skips nothing. Identifiers marked
/// UNCONFIRMED were not seen on a real install; a check lists each app by name.
public enum PasswordManagerApps {
    public static let apps: [(name: String, bundleIDs: [String])] = [
        ("1Password", ["com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
                       "com.agilebits.onepassword4"]),
        ("Bitwarden", ["com.bitwarden.desktop"]),
        ("Apple Passwords", ["com.apple.Passwords"]),
        ("Keychain Access", ["com.apple.keychainaccess"]),
        ("LastPass", ["com.lastpass.LastPass", "com.lastpass.lastpassmacdesktop"]),   // App Store edition UNCONFIRMED
        ("Dashlane", ["com.dashlane.Dashlane", "com.dashlane.dashlanephonefinal"]),   // second UNCONFIRMED
        ("KeePassXC", ["org.keepassxc.keepassxc"]),
        ("Proton Pass", ["me.proton.pass.electron", "me.proton.pass.catalyst"]),      // catalyst UNCONFIRMED
        ("Enpass", ["in.sinew.Enpass-Desktop", "in.sinew.Enpass-Desktop.App"]),       // App Store edition UNCONFIRMED
        ("NordPass", ["com.nordsec.nordpass"]),
        ("Keeper", ["com.keepersecurity.passwordmanager", "com.callpod.keepermac"]),  // both UNCONFIRMED
        ("RoboForm", ["com.siber.RoboForm", "com.siber.roboform.mac"]),               // both UNCONFIRMED
        ("Strongbox", ["com.markmcguill.strongbox.mac", "com.markmcguill.strongbox.mac.pro"]),
        ("KeePassium", ["com.keepassium.ios"]),                                        // Mac Catalyst app UNCONFIRMED
        ("MacPass", ["com.hicknhacksoftware.MacPass"]),
        ("Buttercup", ["pw.buttercup.desktop"]),
        ("Secrets", ["com.outercorner.Secrets"]),                                      // UNCONFIRMED
    ]
    /// Every identifier above, in order, without repeats.
    public static let bundleIDs: [String] = {
        var seen = Set<String>()
        return apps.flatMap(\.bundleIDs).filter { seen.insert($0).inserted }
    }()
}
