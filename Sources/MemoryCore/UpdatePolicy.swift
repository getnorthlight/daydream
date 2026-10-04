import Foundation
import CryptoKit

/// Sparkle update settings read from the app's Info.plist.
///
/// Release builds get these keys from `packaging/updates.json`, written in by
/// `scripts/developer-id-release.py stage`. Development builds, the owner's copy and the private QA copy
/// (`--updates off`) have none of them, so `init(info:)` throws and the app never creates Sparkle: no check, no download.
/// A binary compiled for the private QA copy (DAYDREAM_QA_HARNESS) or the Live Test copy (DAYDREAM_LIVETEST) refuses
/// even if its Info.plist had them (`compiledOff`).
///
/// The feed is `https://<DaydreamUpdateSite>/appcast.xml` (DayDream's website). Update archives are assets of a GitHub
/// release of the same owner/repository, or .zip files on the site or one of its subdomains.
/// A release downloads a found update quietly and installs it when DayDream quits or when the person chooses
/// Restart to Update (SUAutomaticallyUpdate and SUAllowsAutomaticUpdates true); a copy without them runs no updater.
public struct UpdateConfiguration {
    public let owner:String, repository:String, site:String, feed:URL, publicKey:Data
    #if DAYDREAM_QA_HARNESS || DAYDREAM_LIVETEST
    /// The private QA copy and the Live Test copy never update, whatever their Info.plist says.
    public static let compiledOff=true
    #else
    public static let compiledOff=false
    #endif
    public init(info:[String:Any]) throws {
        guard !Self.compiledOff,
              let owner=info["MacMemGitHubOwner"] as? String,
              let repo=info["MacMemGitHubRepository"] as? String,
              [owner,repo].allSatisfy(Self.realName),
              let site=info["DaydreamUpdateSite"] as? String, Self.realSite(site),
              let raw=info["SUFeedURL"] as? String,
              raw == Self.feedURL(site:site), let feed=URL(string:raw),
              let encoded=info["SUPublicEDKey"] as? String, let key=Data(base64Encoded:encoded), key.count == 32, Set(key).count > 1,
              info["SUVerifyUpdateBeforeExtraction"] as? Bool == true,
              info["SURequireSignedFeed"] as? Bool == true,
              // Quiet updates: Sparkle downloads by itself and installs at the quit or at Restart to Update. A copy
              // configured any other way runs no updater (it would show Sparkle's own windows).
              info["SUAllowsAutomaticUpdates"] as? Bool == true,
              info["SUAutomaticallyUpdate"] as? Bool == true else { throw MemError.invalid("Updates unavailable: configure the update site, its appcast, the GitHub owner/repository and the signing public key.") }
        self.owner=owner; repository=repo; self.site=site; self.feed=feed; publicKey=key
    }
    /// The only feed a release accepts: appcast.xml at the root of DayDream's website.
    public static func feedURL(site:String)->String { "https://\(site)/appcast.xml" }
    /// An update archive: an https .zip that is a GitHub release asset of owner/repository, or that lives on the site
    /// or one of its subdomains. The archive's EdDSA signature is what makes it trusted; this only narrows the hosts.
    public func permitsArchive(_ url:URL?) -> Bool {
        guard let url, url.scheme == "https", let host=url.host?.lowercased(), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.port == nil else { return false }
        let parts=url.path.split(separator:"/",omittingEmptySubsequences:false)
        guard parts.count >= 2, parts[0].isEmpty, parts.dropFirst().allSatisfy({ Self.realName(String($0)) }),
              parts.last?.hasSuffix(".zip") == true else { return false }
        if host == "github.com" {
            return parts.count == 7 && parts[1] == owner && parts[2] == repository && parts[3] == "releases" && parts[4] == "download"
        }
        return host == site || host.hasSuffix("." + site)
    }
    private static func realName(_ value:String)->Bool {
        value.range(of:"^[A-Za-z0-9][A-Za-z0-9._-]*$",options:.regularExpression) != nil && !value.contains("..")
            && !["owner","repo","repository","example","placeholder","replace","todo","your-","your_","changeme"].contains(where:{ value.lowercased().contains($0) })
    }
    private static func realSite(_ value:String)->Bool {
        value.range(of:"^([a-z0-9]([a-z0-9-]*[a-z0-9])?\\.)+[a-z]{2,}$",options:.regularExpression) != nil
            && !["example","placeholder","replace","todo","your-","your_","changeme","invalid","localhost","github.io"].contains(where:{ value.contains($0) })
    }
    /// An update may start only when no replacement of an older install is half done.
    public static func replacementAllowsUpdate(phase:String?,busy:Bool)->Bool {
        !busy && (phase == nil || phase == "committed" || phase == "rolled_back")
    }
    public static func newer(_ candidate:String,than installed:String) -> Bool {
        guard let next=UInt64(candidate), let current=UInt64(installed), next > current else { return false }
        return true
    }
    public static func verifies(data:Data,signature:Data,publicKey:Data) -> Bool {
        guard let key=try? Curve25519.Signing.PublicKey(rawRepresentation:publicKey) else { return false }
        return key.isValidSignature(signature,for:data)
    }
}

/// The error domain Sparkle reports (not page text, so it lives outside `UpdateText`).
public enum UpdateErrorDomain { public static let sparkle="SUSparkleErrorDomain" }

/// Every sentence the updates page shows. Plain words, short sentences, and true for
/// what `Updates` (Sources/MacMemApp/Updates.swift) and Sparkle actually do. The page is one card: a status line
/// with Check Now, and one switch (it replaced a page with Sparkle's raw error text, two checkboxes and two notes).
/// The switch turns checking and quiet downloading on and off together, so there is no second one.
/// A downloaded update waits for the next quit, or for Restart to Update; nothing pops up for it.
public enum UpdateText {
    public static let notConfigured="Updates aren't set up in this copy of DayDream. Get new versions from DayDream's GitHub releases page."
    public static let upToDate="You have the latest version."
    public static let checking="Checking…"
    public static let blockedByReplacement="Finish replacing the older install first, then check for updates."
    public static func available(_ version:String)->String { "DayDream \(version) is available." }
    /// A failed check, in plain words: never Sparkle's own text (it reads like a crash report).
    public static let unreachable="Couldn't reach the update server. Try again later."
    public static let installFailed="Couldn't install the update. Try again later."
    public static let checkFailed="Couldn't check for updates. Try again later."
    public static let moveToApplications="Move DayDream to Applications, then check again."
    public static let checkTitle="Check Now"
    public static let switchTitle="Update automatically"
    /// The one network fact (PRIVACY.md has the long form). Under the switch.
    public static let sourceNote="A check sends DayDream's website your IP address and app version."
    /// A downloaded update waiting for the restart (the status line).
    public static func ready(_ version:String)->String { "DayDream \(version) is ready." }
    /// The one action for a downloaded update: the menu bar menu's row, the app menu's item and the Settings button.
    public static let restartTitle="Restart to Update"
    /// The action for an update Sparkle couldn't download by itself (for example it needs an administrator's
    /// password): opens Sparkle's update window, only when the person picks it.
    public static let reviewTitle="Update DayDream…"
    /// The status line's title: the running version.
    public static func versionTitle(_ version:String?)->String { version.map { "DayDream \($0)" } ?? "DayDream" }
    /// The status line when nothing has happened since launch: when the last check ran, if one has.
    public static func lastChecked(_ date:Date?,now:Date)->String? {
        guard let date else { return nil }
        if abs(now.timeIntervalSince(date)) < 60 { return "Checked just now." }
        let formatter=RelativeDateTimeFormatter(); formatter.unitsStyle = .full
        return "Last checked " + formatter.localizedString(for:date,relativeTo:now) + "."
    }
    /// What a failed check or install says. `domain`/`code`: the error Sparkle reported (its domain is
    /// `UpdateErrorDomain.sparkle`; codes from SUErrors.h). `underlyingDomain`: its NSUnderlyingError's domain, if any.
    public static func failure(domain:String,code:Int,underlyingDomain:String?)->String {
        if domain == NSURLErrorDomain || underlyingDomain == NSURLErrorDomain { return unreachable }
        guard domain == UpdateErrorDomain.sparkle else { return checkFailed }
        switch code {
        case 1003, 1005: return moveToApplications         // running from the disk image, or translocated
        case 2001: return unreachable                       // the update's download didn't arrive
        case 2000, 3000...4999: return installFailed        // unpacking, signature, installation
        // 1000, 1002: the update page was reached but isn't a readable list of versions (for example a copy whose
        // page isn't published yet: GitHub answers "not found"); 1004: resuming a downloaded update didn't work.
        default: return checkFailed
        }
    }
    /// The status line after a check or install stopped with that error, or nil to leave the line as it is.
    /// - `asked`: the person pressed Check Now, so the answer is shown whatever it is.
    /// - A scheduled check that couldn't reach or read the update page says nothing (the line keeps what it said, or
    ///   when the last check ran), and the next good check says so. Otherwise a copy whose update page isn't
    ///   published yet, or a Mac that was offline for one check, would show an error for good.
    /// - The person cancelled the password prompt, or chose to install later (4007, 4008): not a failure.
    public static func failureLine(asked:Bool,domain:String,code:Int,underlyingDomain:String?)->String? {
        if domain == UpdateErrorDomain.sparkle && (code == 4007 || code == 4008) { return nil }
        let line=failure(domain:domain,code:code,underlyingDomain:underlyingDomain)
        return asked || (line != unreachable && line != checkFailed) ? line : nil
    }
    public static let all=[notConfigured,upToDate,checking,blockedByReplacement,unreachable,installFailed,checkFailed,moveToApplications,checkTitle,switchTitle,sourceNote,restartTitle,reviewTitle]
}

/// An update waiting for the person, never shown by itself: the menu bar menu, the app menu and Settings offer one
/// action for it, and nothing else changes until they pick it (or quit, which installs a downloaded one).
public enum UpdateWaiting: Equatable, Sendable {
    /// Downloaded and verified; Restart to Update installs it and opens DayDream again.
    case restart(version:String)
    /// Found, but Sparkle needs the person (an administrator's password, or an update it won't install by itself):
    /// Update DayDream… opens Sparkle's window.
    case review(version:String)
    public var title:String { if case .restart = self { return UpdateText.restartTitle } else { return UpdateText.reviewTitle } }
    public var version:String { switch self { case .restart(let v), .review(let v): return v } }
    public var statusLine:String { if case .restart = self { return UpdateText.ready(version) } else { return UpdateText.available(version) } }
}

/// Recording starts again by itself after an update relaunch, when it was on before (sat5: the owner shouldn't
/// have to remember to press Start after every update). Pure rules; `Updates` writes the marker and
/// `MemoryViewModel` reads it at launch.
///
/// - The marker is written only as Sparkle relaunches DayDream after installing, and only if recording was on
///   (not paused, not stopped) then. Quitting writes nothing: a launch the person started never starts recording.
/// - It is removed when the install stops, or when DayDream is still running a minute after the relaunch began
///   (`Updates.relaunchGrace`): a relaunch that didn't happen leaves nothing that starts recording later.
/// - It is read once and removed at the next launch, and counts only if it is recent (`window`).
/// - The start itself is the person's Start (`startCapture`), after `resumeBlocker()` says nothing blocks it. That
///   reads the permissions (a preflight, never a request), so a copy macOS no longer trusts stays off and says why.
public enum UpdateResume {
    public static let key="DaydreamResumeAfterUpdateV1"
    /// How long after the relaunch began the marker still counts.
    public static let window:TimeInterval=15*60
    public static func marker(build:String,at date:Date)->[String:Any] { ["build":build,"at":date.timeIntervalSince1970] }
    /// Leaves the marker for the relaunch Sparkle is starting.
    public static func record(_ defaults:UserDefaults,build:String,at date:Date) { defaults.set(marker(build:build,at:date),forKey:key) }
    /// Removes the marker: the relaunch it describes won't happen.
    public static func clear(_ defaults:UserDefaults) { defaults.removeObject(forKey:key) }
    /// Whether this launch is the update relaunch the marker describes.
    public static func shouldResume(marker:[String:Any]?,now:Date)->Bool {
        guard let marker,let at=marker["at"] as? Double,let build=marker["build"] as? String,!build.isEmpty else { return false }
        let age=now.timeIntervalSince1970-at
        return age >= -60 && age <= window
    }
    /// Reads and removes the marker: it is used at most once.
    public static func consume(_ defaults:UserDefaults,now:Date)->Bool {
        consume(read:{ defaults.dictionary(forKey:key) },remove:{ defaults.removeObject(forKey:key) },now:now)
    }
    /// The same over any store (the checks use one in memory, never the real preferences).
    public static func consume(read:()->[String:Any]?,remove:()->Void,now:Date)->Bool {
        let marker=read()
        remove()
        return shouldResume(marker:marker,now:now)
    }
}
