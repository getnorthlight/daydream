import Foundation
import CoreServices
import HistoryCore
import PrivacyPolicy

/// A metadata-only Chrome observation. Not a grant to record page/field text.
public struct BrowserVerification: Codable, Equatable {
    public var provider: String
    public var mode: String
    public var windowID: String
    public var tabID: String
    public var focusedRole: String
    public var checkedAt: String
    public var documentID:String? = nil
    public var frameID:Int? = nil
    public var navigationGeneration:Int? = nil
    public var focusID:String? = nil
    public var focusGeneration:Int? = nil
    public var sessionID:String? = nil
    public var policyRevision:String? = nil
    public var captureGeneration:UInt64? = nil
    public var captureEpoch:String? = nil
    public var extensionID:String? = nil
    public var browserNamespace:String? = nil
    public var continuousNanoseconds:UInt64? = nil
    public init(mode:String,windowID:String,tabID:String,focusedRole:String,checkedAt:String,provider:String="chrome-appleevents-v1") {
        self.mode=mode; self.windowID=windowID; self.tabID=tabID
        self.focusedRole=focusedRole; self.checkedAt=checkedAt; self.provider=provider
    }
}
public enum BrowserSafety {
    public static let supportedBundle = "com.google.Chrome"
    /// Chrome page history: the only proof a new Chrome row can carry. The
    /// retired "chrome-appleevents-v1" provider had no producer; rows with it
    /// are refused at write time and hidden at read time.
    public static let pageProvider = "chrome-appleevents-page-v1"
    /// Chrome app time (live test, build 7): "Google Chrome" and when, nothing else. Written while "Web pages in
    /// Chrome" is on but the page can't be read (Chrome not verified, Automation not allowed, two copies open), so
    /// Chrome's time doesn't vanish from the day. No title, address, window, tab, text or click.
    public static let appTimeProvider = "chrome-app-time-v1"
    // Deliberately exclude text fields, groups, web areas and unknown roles.
    // This first supported path records metadata only while a clearly
    // non-editable native AX control has keyboard focus.
    public static let safeFocusRoles: Set<String> = ["AXButton","AXLink","AXStaticText","AXCheckBox","AXRadioButton","AXMenuItem"]
    public static func valid(_ e:Evidence) -> Bool {
        if e.browserVerification?.provider == "browser-extension-v3" {return browserOwned(e)}
        if e.browserVerification?.provider == pageProvider {return page(e)}
        if e.browserVerification?.provider == appTimeProvider {return appTime(e)}
        #if DAYDREAM_OWNER_TYPING
        // Owner build: a website typing row (the Chrome join's proof).
        if e.browserVerification?.provider == WebTypedRow.provider || e.browserVerification?.provider == WebTypedRow.searchProvider {return WebTypedRow.valid(e)}
        #endif
        guard e.bundle == supportedBundle, let proof=e.browserVerification,
              proof.provider == "chrome-native-bridge-v1", proof.mode == "normal",
              !proof.windowID.isEmpty, !proof.tabID.isEmpty,
              proof.windowID.count <= 80, proof.tabID.count <= 80,
              safeFocusRoles.contains(proof.focusedRole),
              let observed=timestamp(e.at), let checked=timestamp(proof.checkedAt),
              abs(observed.timeIntervalSince(checked)) <= 1,
              e.text.isEmpty, !e.secure, !e.privateWindow else { return false }
        guard ["browser.observed","browser.tab_visited"].contains(e.kind), e.title.isEmpty,
              let url=URLComponents(string:e.url),["http","https"].contains(url.scheme),url.host != nil,
              url.user == nil,url.password == nil,url.query == nil,url.fragment == nil,["","/"].contains(url.path),
              proof.frameID == 0,(proof.navigationGeneration ?? -1)>=0,(proof.focusGeneration ?? -1)>=0,
              [proof.documentID,proof.focusID,proof.sessionID,proof.policyRevision].allSatisfy({$0.map{!$0.isEmpty && $0.utf8.count<=256} == true}) else { return false }
        return true
    }
    /// One Chrome page row: title (or none), origin and time. Never the path,
    /// query, fragment, page text, a field or a click. No time or setting check:
    /// rows saved while the switch was on stay visible after it is turned off.
    private static func page(_ e:Evidence)->Bool {
        guard e.bundle == supportedBundle, let proof=e.browserVerification,
              proof.provider == pageProvider, proof.mode == "normal",
              ChromeAppleEvents.validID(proof.windowID), ChromeAppleEvents.validID(proof.tabID),
              proof.focusedRole.isEmpty,
              let revision=proof.policyRevision, !revision.isEmpty, revision.utf8.count <= 256,
              e.kind == "window.changed",
              let observed=timestamp(e.at), let checked=timestamp(proof.checkedAt),
              abs(observed.timeIntervalSince(checked)) <= 1,
              e.text.isEmpty, !e.secure, !e.privateWindow, e.title.count <= 160,
              // fix/chrome-root (coordinator decision 10-02, row 8b): the origin, or the origin plus exactly "/" with
              // nothing after it. Builds up to 0.1.4 stored Search & AI page rows as "https://chatgpt.com/" (ingest's
              // TypedHistoryScrub); they are restored read-side (`Privacy.sanitized` shows the bare origin), never by
              // writing to the store. Any real path, query or fragment is still refused.
              let origin=BrowserSites.origin(e.url), e.url == origin || e.url == origin + "/", let host=BrowserSites.host(of:origin),
              !BrowserSites.blockedByDefault(host:host),
              // email-1003 (owner decision 2026-10-03): an email page keeps its cleaned title (`EmailTitle`) when it
              // passes the subject rules and holds no address; search and chat pages stay the site only.
              !BrowserSites.siteOnly(host:host) || e.title.isEmpty
                || (BrowserSites.emailHost(host:host) && EmailTitle.keepable(e.title)) else { return false }
        return true
    }
    /// One Chrome app-time row: the app's name and the time. Everything else is empty.
    private static func appTime(_ e:Evidence)->Bool {
        guard e.bundle == supportedBundle, let proof=e.browserVerification,
              proof.provider == appTimeProvider, proof.mode.isEmpty, proof.windowID.isEmpty, proof.tabID.isEmpty,
              proof.focusedRole.isEmpty, proof.documentID == nil, proof.focusID == nil,
              let revision=proof.policyRevision, !revision.isEmpty, revision.utf8.count <= 256,
              e.kind == "app.activated",
              let observed=timestamp(e.at), let checked=timestamp(proof.checkedAt),
              abs(observed.timeIntervalSince(checked)) <= 1,
              e.title.isEmpty, e.url.isEmpty, e.text.isEmpty, !e.secure, !e.privateWindow,
              e.typed == nil, e.sendVerification == nil else { return false }
        return true
    }
    private static func browserOwned(_ e:Evidence)->Bool {
        guard let p=e.browserVerification,let browser=p.browserNamespace,
              (browser=="chrome" && e.bundle=="com.google.Chrome") || (browser=="safari" && e.bundle=="com.apple.Safari"),
              let ext=p.extensionID,ext.range(of:browser=="chrome" ? "^[a-p]{32}$" : "^[A-Za-z0-9][A-Za-z0-9._-]{1,199}$",options:.regularExpression) != nil,
              ["browser.extension_observed","browser.extension_tab_visited"].contains(e.kind),
              p.mode=="normal",e.text.isEmpty,e.title.isEmpty,!e.secure,!e.privateWindow,
              ["button","link","document"].contains(p.focusedRole),
              p.windowID.count<=20,p.tabID.count<=20,let window=Int(p.windowID),window>=0,let tab=Int(p.tabID),tab>=0,
              p.frameID==0,(p.navigationGeneration ?? 0)>0,(p.focusGeneration ?? 0)>0,(p.captureGeneration ?? 0)>0,
              UUID(uuidString:p.documentID ?? "") != nil,UUID(uuidString:p.focusID ?? "") != nil,
              UUID(uuidString:p.captureEpoch ?? "") != nil,
              (p.sessionID ?? "").range(of:"^[a-f0-9]{32}$",options:.regularExpression) != nil,
              let revision=p.policyRevision,!revision.isEmpty,revision.utf8.count<=256,
              let observed=timestamp(e.at),let checked=timestamp(p.checkedAt),abs(observed.timeIntervalSince(checked))<=1,
              let duration=p.continuousNanoseconds,e.kind != "browser.extension_tab_visited" || duration>=10_000_000_000,
              e.url.utf8.count<=256,let u=URLComponents(string:e.url),["http","https"].contains(u.scheme),u.host != nil,
              u.user==nil,u.password==nil,u.query==nil,u.fragment==nil,["","/"].contains(u.path) else {return false}
        return true
    }
    public static func fresh(_ e:Evidence,now:Date) -> Bool {
        valid(e) && timestamp(e.browserVerification?.checkedAt ?? "").map { (-0.1...1).contains(now.timeIntervalSince($0)) } == true
    }
}

public enum BrowserTarget: Equatable {
    case frontWindow, window(String), activeTab(String), tab(String,String)
}

/// Browsers that aren't on `KnownBrowsers`: any app that registers to open web
/// links (http or https in its Info.plist `CFBundleURLTypes`) is treated as a
/// web browser. Nothing from it is recorded, the same as a known browser: no
/// window titles (usually page titles), web addresses, clicks or typing.
///
/// Matching too much only skips an app (a link router such as a browser
/// picker is skipped too). Not caught: a browser that never registers for web
/// links. The person can still exclude any app in Settings.
///
/// One rule with typing: an app this build can type in (`CaptureGate.nativeApps`, named in the
/// typing table with a confirmed signer) is known by name, so it is never an unknown browser, even
/// when it opens web links (ChatGPT does). It is then recorded like any app and listed as Included,
/// so the person can exclude it. Public builds type only in Notes and TextEdit, which open no web
/// links, so this changes nothing there.
public enum BrowserLookalike {
    /// Apps the build types in: never treated as unknown browsers.
    public static func knownTypingApp(_ bundleID:String) -> Bool { CaptureGate.nativeApps.contains(bundleID) }
    /// The Info.plist of an app declares the http or https URL scheme.
    public static func opensWebLinks(infoPlist:[String:Any]) -> Bool {
        guard let types=infoPlist["CFBundleURLTypes"] as? [[String:Any]] else { return false }
        return types.contains { type in
            ((type["CFBundleURLSchemes"] as? [String]) ?? []).contains { ["http","https"].contains($0.trimmingCharacters(in:.whitespaces).lowercased()) }
        }
    }
    /// The app bundle at `url` (a `.app` folder) declares http or https. Reads only its Info.plist,
    /// once per path while the app runs (Settings asks for every listed app on each redraw).
    public static func opensWebLinks(appAt url:URL) -> Bool {
        let key=url.standardizedFileURL.path
        lock.lock()
        if let known=pathCache[key] { lock.unlock(); return known }
        lock.unlock()
        let found=readsWebLinks(url)
        lock.lock()
        if pathCache.count >= 2048 { pathCache.removeAll() }
        pathCache[key]=found
        lock.unlock()
        return found
    }
    private static func readsWebLinks(_ url:URL) -> Bool {
        let plist=url.appendingPathComponent("Contents/Info.plist")
        guard let size=(try? FileManager.default.attributesOfItem(atPath:plist.path))?[.size] as? NSNumber, size.intValue <= 1_000_000,
              let data=try? Data(contentsOf:plist),
              let info=try? PropertyListSerialization.propertyList(from:data,options:[],format:nil) as? [String:Any] else { return false }
        return opensWebLinks(infoPlist:info)
    }
    /// Where the apps with this bundle ID are installed. Launch Services by default; the checks set it.
    public static var locate:(String)->[URL] = { id in
        (LSCopyApplicationURLsForBundleIdentifier(id as CFString,nil)?.takeRetainedValue() as? [URL]) ?? []
    }
    private static let lock=NSLock()
    private static var cache:[String:Bool]=[:]
    private static var pathCache:[String:Bool]=[:]
    /// Forgets every answer (the checks, after changing `locate`).
    public static func reset() { lock.lock(); cache.removeAll(); pathCache.removeAll(); lock.unlock() }
    /// A browser DayDream doesn't know by name: not on `KnownBrowsers`, and an installed copy
    /// opens web links. Asked once per bundle ID while the app runs.
    public static func isUnknownBrowser(_ bundleID:String) -> Bool {
        let id=bundleID.trimmingCharacters(in:.whitespacesAndNewlines)
        guard !id.isEmpty, !KnownBrowsers.contains(id), !knownTypingApp(id) else { return false }
        lock.lock()
        if let known=cache[id] { lock.unlock(); return known }
        lock.unlock()
        let found=locate(id).contains { opensWebLinks(appAt:$0) }
        lock.lock()
        if cache.count >= 512 { cache.removeAll() }
        cache[id]=found
        lock.unlock()
        return found
    }
    /// Skipped as a browser: known by name, or an unknown app that opens web links.
    /// `appURL`, when known (the installed app list), is read directly.
    public static func skips(_ bundleID:String, appURL:URL?=nil) -> Bool {
        if KnownBrowsers.contains(bundleID) { return true }
        if knownTypingApp(bundleID) { return false }
        if let appURL { return opensWebLinks(appAt:appURL) }
        return isUnknownBrowser(bundleID)
    }
}
