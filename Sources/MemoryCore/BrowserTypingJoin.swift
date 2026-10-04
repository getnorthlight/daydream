#if DAYDREAM_CHROME_TYPING
// Compiled only with -DDAYDREAM_CHROME_TYPING: every release build defines it; a plain swift build leaves this file out.
//
// Pure, fail-closed join between Chrome's Apple Events view ("this window is
// normal") and the Accessibility view ("the key is going into this field").
// No OS calls: production supplies the Apple Event transport
// (ChromeModeReader.JoinSession) and the AX adapter (ChromeTypingWitness).
// Rules (owner decisions override the plan where they differ):
// - strict Incognito: any Incognito/Guest/unknown window => deny, and only
//   one Chrome process may be running (Apple Events see one process at a time);
// - every window's `mode` is read before any bounds, name, tab or URL, and
//   before any Accessibility read of window or page content;
// - every window Accessibility shows must be a window Apple Events listed
//   (geometry only), before any title or page is read: an Incognito window
//   that is opening or closing may be missing from the Apple Events list;
// - AE<->AX match on bounds + name + URL origin + exactly one AXWebArea;
// - card, one-time-code, PIN, password and web-terminal fields are denied by
//   their label, id, placeholder or class (deny-only, never stored);
// - SYNCHRONOUS DESIGN ONLY: everything is read twice and must be unchanged,
//   within `BrowserTypingTiming.joinBudgetNanoseconds` (fix/chrome-root: 500 ms;
//   was 150 ms, which no join on the owner's Mac could meet: see the constant);
// - a key whose processing starts more than 150 ms after it was typed is
//   dropped (the tap's input-lag bound, in both designs). SYNCHRONOUS DESIGN
//   ONLY: every check describes the moment DayDream starts processing the key
//   (the join starts after the key and finishes within its budget). In the QF-17 bracketed
//   design attribution instead uses the per-fact bracket (a key between two
//   verified, equal reads, each fact's span at most 150 ms; ChromeBracket.swift);
// - a quiet period after shortcuts, Return, Tab, arrows, clicks and denials;
// - the window list must be identical at burst start and at save;
// - "everywhere except a block list": suffix-matched blocks always win;
// - the only output is the origin (scheme://host[:port]).
// Website typing (owner build): the burst rules run on TypingSession, the
// same unit model native typing uses, with WebTypingGate as its gate.
import Foundation
import PrivacyPolicy

public enum BrowserTypingTiming {
    /// Whole double-read join (noext §2.2). fix/chrome-root (2026-10-02): was 150 ms. On the owner's Mac every Apple
    /// Event to Chrome takes 8-17 ms (median 12.5 ms with Chrome in front; Finder answers in 8.3 ms too, so it is the
    /// system's Apple Event round trip, not Chrome), and the double read asks 16 of them even with the batched mode
    /// and bounds reads (it asked 26 for three windows before), so a join needs about 200 ms: every join was refused
    /// (`timeout`, or `notNormal`/`windowList` when one event ran past its 20 ms timeout) and no website typing was
    /// ever saved. The double read and every check in it are unchanged; this is
    /// only how long the two reads may take together.
    public static let joinBudgetNanoseconds: UInt64 = 500_000_000
    /// Keys dropped after a shortcut, Return, Tab, arrow, click or denied key (300–500 ms).
    public static let quietNanoseconds: UInt64 = 400_000_000
    /// A proof older than this cannot admit a key or a save (CaptureGate.ttlNanoseconds).
    public static let proofTTLNanoseconds: UInt64 = 1_000_000_000
    /// A key (or Return) processed later than this after it was typed is
    /// dropped with its burst (the tap's input-lag bound, both designs).
    /// fix/chrome-root: in the synchronous design "processed" is when the key's join STARTED (`checkedAt`): the join
    /// itself takes longer than this on a real Mac (`joinBudgetNanoseconds`), and it describes the moment after
    /// the key either way (`fresh`: it started after the key was typed).
    /// SYNCHRONOUS DESIGN ONLY: the join describes the moment of processing;
    /// a late key may have gone to a window that has closed since (Incognito,
    /// Spotlight, a blocked page). The QF-17 bracketed design does not use
    /// this for attribution: see `ChromeBracketTiming.spanNanoseconds`.
    public static let maxKeyLagNanoseconds: UInt64 = 150_000_000
    /// The light per-key check between full joins (`BrowserTypingJoin.light`;
    /// tools/chrome-device-test F5). Slower than this, the full join decides.
    /// fix/chrome-root: was 30 ms, less than the three Apple Events it asks take on the owner's Mac (about 40 ms),
    /// so it never vouched for a key and every key took a full join.
    public static let lightBudgetNanoseconds: UInt64 = 120_000_000
    /// fix/web-textbox (battery): after a key's join refused the page or the
    /// field for privacy (a blocked site or one whose switch is off, an
    /// Incognito or Guest window, a sensitive field), plain keys typed within
    /// this long are dropped with no read at all, until a click, Return, Tab,
    /// shortcut, app switch or policy change (`BrowserTypingBurst.heldUntil`).
    /// Dropping a key can only lose typing, never keep it.
    public static let refusedHoldNanoseconds: UInt64 = 1_000_000_000
    /// fix/chrome-x (perf, 10-03: 28 full joins in 18 s, ~100 ms each on main, while an X reply was refused `window`):
    /// the longest a refused page episode (`BrowserTypingBurst.episodeDenials`) is held with no new join while the
    /// same window, field and window title keep focus. After it, one key joins again (a refusal that has since
    /// cleared, an unread count that caught up, is found within this).
    public static let episodeHoldNanoseconds: UInt64 = 3_000_000_000
    public static let maxWindows = 64
    /// The focused field's parent walk to its window (the join's step 11).
    /// fix/x-typing (test 7: nothing typed on x.com was kept): 48 refused X's
    /// post box as `.frame`. X is built with React Native for Web, whose every
    /// `<div>` is positioned, so Chrome exposes each one as an AXGroup: the
    /// box is about 45 groups below the page, and Chrome's own views add more
    /// above the AXWebArea (claude.ai's box is about 20 steps). A bound, not a
    /// guess at depth: the cycle check, `late()` against the join's budget and
    /// the one-AXWebArea rule still end every walk.
    public static let maxAncestors = 160
}

// MARK: - Apple Event vocabulary of the join

/// Everything the join may ask Chrome. Each case is one `core/getd` of one
/// allowlisted property, addressed by window ID (never by position), except
/// `windowIDs`, which asks only for the IDs of every window.
public enum ChromeJoinRequest: Equatable, Sendable {
    case windowIDs                  // ID of every window
    /// QF-17 (M6, bracketed design only): `mode of every window`. The reply must list exactly as many values as
    /// `windowIDs` did, every one exactly "normal" (the join checks; the decoder accepts only text items).
    case modes                      // mode of every window
    /// QF-17 (M6, bracketed design only): `bounds of every window`, paired with `windowIDs` by index only while
    /// the ID list read before and after it is identical.
    case allBounds                  // bounds of every window
    case mode(String)               // mode of window id W
    case bounds(String)             // bounds of window id W
    case name(String)               // name of window id W (page-authored title)
    case activeTabID(String)        // ID of active tab of window id W
    case tabURL(String, String)     // URL of tab id T of window id W

    public var property: String {
        switch self {
        case .windowIDs, .activeTabID: return "ID  "
        case .mode, .modes: return "mode"
        case .bounds, .allBounds: return "pbnd"
        case .name: return "pnam"
        case .tabURL: return "URL "
        }
    }
    public var windowID: String? {
        switch self {
        case .windowIDs, .modes, .allBounds: return nil
        case .mode(let w), .bounds(let w), .name(let w), .activeTabID(let w), .tabURL(let w, _): return w
        }
    }
    /// The audited object specifier, or nil. Built only by `ChromeAppleEvents`.
    public var specifier: NSAppleEventDescriptor? {
        let built: NSAppleEventDescriptor?
        switch self {
        case .windowIDs: built = ChromeAppleEvents.everyWindow().flatMap { ChromeAppleEvents.property("ID  ", of: $0) }
        case .modes: built = ChromeAppleEvents.everyWindow().flatMap { ChromeAppleEvents.property("mode", of: $0) }
        case .allBounds: built = ChromeAppleEvents.everyWindow().flatMap { ChromeAppleEvents.property("pbnd", of: $0) }
        case .mode(let w): built = ChromeAppleEvents.specifier(.window(w), property: "mode")
        case .bounds(let w): built = ChromeAppleEvents.specifier(.window(w), property: "pbnd")
        case .name(let w): built = ChromeAppleEvents.specifier(.window(w), property: "pnam")
        case .activeTabID(let w): built = ChromeAppleEvents.specifier(.activeTab(w), property: "ID  ")
        case .tabURL(let w, let t): built = ChromeAppleEvents.specifier(.tab(w, t), property: "URL ")
        }
        return built.flatMap { ChromeAppleEvents.audit($0, everyWindow: Self.everyWindow) ? $0 : nil }
    }
    /// QF-17 M6 + PM7: the `every window` properties Chrome typing's reads may ask for (one event each). Only
    /// Chrome typing's own session passes these to the sender's audit.
    public static let everyWindow: Set<String> = ["ID  ", "mode", "pbnd"]
    /// Pure reply decoding. Anything unexpected is nil (deny).
    public func decode(_ d: NSAppleEventDescriptor) -> ChromeJoinReply? {
        switch self {
        case .windowIDs:
            if d.descriptorType == ChromeAppleEvents.code("list") {
                guard d.numberOfItems <= BrowserTypingTiming.maxWindows else { return nil }
                var ids: [String] = []
                for i in stride(from: 1, through: d.numberOfItems, by: 1) {
                    guard let id = d.atIndex(i)?.stringValue else { return nil }
                    ids.append(id)
                }
                return .ids(ids)
            }
            return d.stringValue.map { .ids([$0]) }
        case .modes:
            // A list of text items, or one text item for a single window. Anything else denies.
            let text = [ChromeAppleEvents.code("utxt"), ChromeAppleEvents.code("TEXT")]
            if d.descriptorType == ChromeAppleEvents.code("list") {
                guard d.numberOfItems <= BrowserTypingTiming.maxWindows else { return nil }
                var out: [String] = []
                for i in stride(from: 1, through: d.numberOfItems, by: 1) {
                    guard let item = d.atIndex(i), text.contains(item.descriptorType), let v = item.stringValue else { return nil }
                    out.append(v)
                }
                return .texts(out)
            }
            guard text.contains(d.descriptorType), let v = d.stringValue else { return nil }
            return .texts([v])
        case .allBounds:
            // A list of bounds; one window's bounds may come unwrapped (a QuickDraw rect or a 4-item list).
            if d.descriptorType == ChromeAppleEvents.code("list"), d.numberOfItems >= 1,
               let firstItem = d.atIndex(1), [ChromeAppleEvents.code("qdrt"), ChromeAppleEvents.code("list")].contains(firstItem.descriptorType) {
                guard d.numberOfItems <= BrowserTypingTiming.maxWindows else { return nil }
                var out: [ChromeBounds] = []
                for i in stride(from: 1, through: d.numberOfItems, by: 1) {
                    guard let item = d.atIndex(i), let b = ChromeBounds(descriptor: item) else { return nil }
                    out.append(b)
                }
                return .boundsList(out)
            }
            return ChromeBounds(descriptor: d).map { .boundsList([$0]) }
        case .bounds:
            return ChromeBounds(descriptor: d).map { .bounds($0) }
        case .mode, .name, .activeTabID, .tabURL:
            guard [ChromeAppleEvents.code("utxt"), ChromeAppleEvents.code("TEXT")].contains(d.descriptorType) else { return nil }
            return d.stringValue.map { .text($0) }
        }
    }
}
public enum ChromeJoinReply: Equatable, Sendable {
    case ids([String])
    case text(String)
    case bounds(ChromeBounds)
    /// QF-17: `mode of every window`.
    case texts([String])
    /// QF-17: `bounds of every window`.
    case boundsList([ChromeBounds])
}

/// A window rectangle in global top-left-origin points.
public struct ChromeBounds: Equatable, Sendable {
    public var left: Double, top: Double, right: Double, bottom: Double
    public init(left: Double, top: Double, right: Double, bottom: Double) {
        self.left = left; self.top = top; self.right = right; self.bottom = bottom
    }
    /// From Accessibility's AXPosition + AXSize.
    public init(x: Double, y: Double, width: Double, height: Double) {
        self.init(left: x, top: y, right: x + width, bottom: y + height)
    }
    /// Chrome answers `bounds` with a QuickDraw Rect (`typeQDRectangle`:
    /// top, left, bottom, right as Int16; `boundsAsQDRect` in Chrome's sdef).
    /// AppleScript-style lists {left, top, right, bottom} are accepted too.
    /// The coordinate match against AX is UNCONFIRMED on multi-display setups.
    public init?(descriptor d: NSAppleEventDescriptor) {
        if d.descriptorType == ChromeAppleEvents.code("qdrt"), d.data.count == 8 {
            let v = d.data.withUnsafeBytes { raw in (0..<4).map { Double(raw.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)) } }
            self.init(left: v[1], top: v[0], right: v[3], bottom: v[2])
        } else if d.descriptorType == ChromeAppleEvents.code("list"), d.numberOfItems == 4 {
            let v = (1...4).compactMap { d.atIndex($0).map { Double($0.int32Value) } }
            guard v.count == 4 else { return nil }
            self.init(left: v[0], top: v[1], right: v[2], bottom: v[3])
        } else { return nil }
        guard valid else { return nil }
    }
    public var valid: Bool {
        [left, top, right, bottom].allSatisfy { $0.isFinite } && right > left && bottom > top
    }
    public func matches(_ other: ChromeBounds, tolerance: Double = 1) -> Bool {
        abs(left - other.left) <= tolerance && abs(top - other.top) <= tolerance
            && abs(right - other.right) <= tolerance && abs(bottom - other.bottom) <= tolerance
    }
}

// MARK: - The target process

/// What production reads about the running Chrome before any Apple Event:
/// its code signature (Google, Team EQHXZ8M8AV) and its version from the bundle.
public struct ChromeTargetFacts: Equatable, Sendable {
    public var pid: Int32
    public var bundleID: String
    /// pid + launch date; a relaunch is a different target.
    public var launchIdentity: String
    /// The running code satisfies `ChromeTargetPolicy.requirement`.
    public var signatureValid: Bool
    public var bundleVersion: String?
    /// Every `Google Chrome Framework.framework/Versions/<v>` present. Chrome
    /// keeps the running version there, so requiring all of them to be new
    /// enough covers "updated on disk, old version still running".
    public var frameworkVersions: [String]
    /// The person's running `com.google.Chrome` application processes
    /// (`ChromeProcesses.user`). Another `--user-data-dir` instance with
    /// windows is a second process with its own windows, which this process's
    /// Apple Events never list. Strict mode ("any Incognito window pauses
    /// Chrome typing") needs exactly one. A headless or automation Chrome (no
    /// window, not in front) has no window to be Incognito and is not counted.
    public var instances: Int
    public init(pid: Int32, bundleID: String, launchIdentity: String, signatureValid: Bool, bundleVersion: String?, frameworkVersions: [String], instances: Int) {
        self.pid = pid; self.bundleID = bundleID; self.launchIdentity = launchIdentity
        self.signatureValid = signatureValid; self.bundleVersion = bundleVersion; self.frameworkVersions = frameworkVersions
        self.instances = instances
    }
}
public enum ChromeTargetPolicy {
    public static let bundleID = "com.google.Chrome"
    public static let teamID = ChromePageTarget.teamID
    /// The "show password" secure-input bypass (Chromium 519233776,
    /// CVE-2026-17975) is fixed in M151.
    public static let minimumMajorVersion = 151
    /// Google's Developer ID for Chrome (stable channel only). Checked read-only
    /// against the installed Chrome 153 with `codesign --verify -R`.
    public static let requirement = ChromePageTarget.requirement
    public static let frameworkVersionsPath = "Contents/Frameworks/Google Chrome Framework.framework/Versions"

    /// "153.0.8010.54" -> 153. Only dotted decimal versions are accepted.
    public static func majorVersion(_ version: String) -> Int? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.count <= 6 && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }) else { return nil }
        return Int(parts[0])
    }
    public static func versionAllowed(_ version: String?) -> Bool {
        version.flatMap(majorVersion).map { $0 >= minimumMajorVersion } ?? false
    }
    public static func accepts(_ f: ChromeTargetFacts) -> Bool {
        f.pid > 0 && f.bundleID == bundleID && f.signatureValid && !f.launchIdentity.isEmpty
            && versionAllowed(f.bundleVersion)
            && !f.frameworkVersions.isEmpty && f.frameworkVersions.allSatisfy { versionAllowed($0) }
            && f.instances == 1
    }
    /// Reads the version facts from a bundle on disk. Reads files only; never
    /// launches or loads the bundle (Bundle(url:) caches, so the plist is read directly).
    public static func bundleVersions(at bundle: URL) -> (bundleVersion: String?, frameworkVersions: [String]) {
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        let info = (try? Data(contentsOf: plist)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let versions = (try? FileManager.default.contentsOfDirectory(atPath: bundle.appendingPathComponent(frameworkVersionsPath).path)) ?? []
        return (info?["CFBundleShortVersionString"] as? String, versions.filter { $0 != "Current" && !$0.hasPrefix(".") }.sorted())
    }
}


/// Per-key cost (typing-all final review): every key in Chrome runs a full
/// join. Facts that can't change while one Chrome process runs are read once
/// per launch: the versions on disk it was checked against (the signature is
/// cached per launch by `ChromeEventSender`). The Automation answer is reused
/// for at most `ttl`, and only while it said yes. Any join that refuses the
/// target or the permission (or any other denial) reads both again. The
/// instance count is read every join: a second Chrome can start at any moment.
public final class ChromeTargetFactsCache {
    public let ttl: UInt64
    private var versions: (launch: String, bundleVersion: String?, frameworkVersions: [String])?
    private var permission: (pid: Int32, launch: String, at: UInt64)?
    /// How often each fact was read from the OS (checks and diagnostics).
    public private(set) var versionReads = 0, permissionReads = 0
    public init(ttlNanoseconds: UInt64 = 1_000_000_000) { ttl = ttlNanoseconds }
    public func versions(launch: String, read: () -> (bundleVersion: String?, frameworkVersions: [String])) -> (bundleVersion: String?, frameworkVersions: [String]) {
        if let v = versions, v.launch == launch { return (v.bundleVersion, v.frameworkVersions) }
        versionReads += 1
        let fresh = read()
        versions = (launch, fresh.bundleVersion, fresh.frameworkVersions)
        return fresh
    }
    public func permitted(pid: Int32, launch: String?, now: UInt64, read: (Int32) -> Bool) -> Bool {
        if let p = permission, let launch, p.pid == pid, p.launch == launch, now >= p.at, now - p.at <= ttl { return true }
        permissionReads += 1
        let allowed = read(pid)
        permission = allowed && launch != nil ? (pid, launch!, now) : nil
        return allowed
    }
    /// After any denial: the next join reads everything again.
    public func invalidate() { versions = nil; permission = nil }
    /// fix/web-textbox (battery): refusals about the page or the focused field
    /// say nothing about which Chrome this is or its Automation permission,
    /// so they keep the cached facts (the versions stay keyed by Chrome's
    /// launch, the permission by its one-second TTL). Every other denial
    /// reads them again.
    public static let pageDenials: Set<BrowserTypingDenial> = [.blockedSite, .field, .sensitiveField]
    public func after(_ denial: BrowserTypingDenial?) {
        guard let denial, !Self.pageDenials.contains(denial) else { return }
        invalidate()
    }
}

// MARK: - Sites: everywhere except a block list

public enum BrowserTypingSiteDecision: Equatable, Sendable {
    case allowed(origin: String)
    case blocked
    case invalid
}

/// The Chrome-typing block list. Suffix matching: a domain blocks itself and
/// every subdomain. Defaults can be removed (except the app-wide sensitive
/// domains, which stay blocked everywhere); sites can be added; one click
/// blocks the current site.
public struct BrowserTypingBlockList: Codable, Equatable, Sendable {
    /// App-wide sensitive domains (Models.swift). Always blocked; not removable here.
    public static var pinned: [String] { PrivacySettings.sensitiveDomains }
    /// The Chrome page history defaults (BrowserSiteList) plus the typing-only web terminals.
    public static let defaults: [String] = BrowserSiteList.pageDefaults + webTerminals
    /// Browser shells, cloud consoles and web IDEs: a terminal in a page is not
    /// a secure field, so a `sudo` password or a pasted key would look like typing.
    static let webTerminals = ["shell.cloud.google.com", "ssh.cloud.google.com", "console.cloud.google.com", "console.aws.amazon.com",
        "shell.azure.com", "portal.azure.com", "github.dev", "vscode.dev", "gitpod.io", "replit.com", "repl.co", "codesandbox.io",
        "csb.app", "stackblitz.com", "glitch.com", "c9.io", "webcontainer.io", "colab.research.google.com"]

    public private(set) var removedDefaults: [String] = []
    public private(set) var added: [String] = []
    public init() {}

    /// Pinned + remaining defaults + user additions, de-duplicated. Built-in
    /// entries are stored normalized (checked); additions are normalized on entry.
    public var effective: [String] {
        var seen = Set<String>(), out: [String] = []
        for d in Self.pinned + Self.defaults.filter({ !removedDefaults.contains($0) }) + added where seen.insert(d).inserted { out.append(d) }
        return out
    }
    @discardableResult public mutating func removeDefault(_ entry: String) -> Bool {
        guard let d = BrowserTypingSites.normalizedDomain(entry), Self.defaults.contains(d),
              !Self.pinned.contains(d), !removedDefaults.contains(d) else { return false }
        removedDefaults.append(d); removedDefaults.sort(); return true
    }
    @discardableResult public mutating func add(_ entry: String) -> Bool {
        guard let d = BrowserTypingSites.normalizedDomain(entry) else { return false }
        if let i = removedDefaults.firstIndex(of: d) { removedDefaults.remove(at: i); return true }
        guard !effective.contains(d) else { return false }
        added.append(d); return true
    }
    @discardableResult public mutating func removeAdded(_ entry: String) -> Bool {
        guard let d = BrowserTypingSites.normalizedDomain(entry), let i = added.firstIndex(of: d) else { return false }
        added.remove(at: i); return true
    }
    /// One click: "Don't record this site". Blocks the origin's host and its subdomains.
    @discardableResult public mutating func blockSite(origin: String) -> Bool {
        guard let host = BrowserTypingSites.host(of: origin) else { return false }
        return add(host)
    }
}

public enum BrowserTypingSites {
    /// The shared Chrome site rules (BrowserSites), plus the console words
    /// that only typing needs: a terminal in a page is not a secure field.
    static let hostKeywords = BrowserSites.hostKeywords
    static let hostLabels: Set<String> = BrowserSites.hostLabels
    static let pathKeywords = BrowserSites.pathKeywords
    static let pathTokens: Set<String> = BrowserSites.pathTokens.union(["terminal", "shell", "ssh", "console", "cloudshell"])
    static let tokenPairs: Set<String> = BrowserSites.tokenPairs

    /// scheme://host[:port] for http(s) only; nil for anything else (deny).
    public static func origin(_ raw: String) -> String? { BrowserSites.origin(raw) }
    public static func host(of raw: String) -> String? { BrowserSites.host(of: raw) }
    private static func parts(_ raw: String) -> (scheme: String, host: String, port: Int?, components: URLComponents)? { BrowserSites.parts(raw) }
    /// Equal after dropping the fragment: same origin, path and query.
    public static func sameDocument(_ a: String, _ b: String) -> Bool {
        guard let x = parts(a), let y = parts(b), x.scheme == y.scheme, x.host == y.host, x.port == y.port else { return false }
        func path(_ c: URLComponents) -> String { c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath }
        return path(x.components) == path(y.components) && x.components.percentEncodedQuery == y.components.percentEncodedQuery
    }
    /// "example.org", "https://example.org/x", "*.example.org", ".Example.org." -> "example.org".
    public static func normalizedDomain(_ entry: String) -> String? { BrowserSites.normalizedDomain(entry) }
    /// Dot-anchored suffix match: "chase.com" blocks "chase.com" and "secure.chase.com", not "notchase.com".
    public static func matches(host: String, domain: String) -> Bool { BrowserSites.matches(host: host, domain: domain) }
    /// Blocks always win. `alwaysBlocked` carries the app-wide lists
    /// (PrivacySettings.sensitiveDomains + the user's blockedDomains).
    /// The existing `?`/`#` rule (CaptureGate.swift:64) applies to the origin
    /// only: the query and fragment are never stored and never read as an
    /// allow; the path, the query and a hash route are checked separately, deny-only.
    public static func evaluate(_ url: String, blockList: BrowserTypingBlockList, alwaysBlocked: [String] = []) -> BrowserTypingSiteDecision {
        guard let p = parts(url), let origin = origin(url) else { return .invalid }
        let domains = alwaysBlocked.compactMap(normalizedDomain) + blockList.effective
        if domains.contains(where: { matches(host: p.host, domain: $0) }) { return .blocked }
        if hostKeywords.contains(where: p.host.contains) { return .blocked }
        if p.host.split(whereSeparator: { $0 == "." || $0 == "-" }).contains(where: { hostLabels.contains(String($0)) }) { return .blocked }
        // Hash-routed apps ("#/login", "#!/checkout") carry their page path in
        // the fragment; it is checked as a path (deny-only), never stored.
        var texts = [p.components.percentEncodedPath]
        if let query = p.components.percentEncodedQuery { texts.append(query.replacingOccurrences(of: "+", with: " ")) }
        if var route = p.components.percentEncodedFragment {
            if route.hasPrefix("!") { route.removeFirst() }
            if route.hasPrefix("/") { texts.append(route) }
        }
        if texts.contains(where: blocks) { return .blocked }
        guard !origin.contains("?"), !origin.contains("#") else { return .invalid }
        return .allowed(origin: origin)
    }
    /// Deny-only reading of a path, query or route, with the typing path tokens.
    static func blocks(_ raw: String) -> Bool { BrowserSites.blocks(raw, pathTokens: pathTokens) }
}

// MARK: - Field labels: deny-only

/// The focused field's accessible labels. Transient: compared against the
/// rules below and dropped; never stored, logged or shown.
public struct BrowserTypingFieldLabels: Equatable, Sendable {
    /// AXTitle, AXDescription and AXPlaceholderValue.
    public var texts: [String]
    /// AXDOMIdentifier and every AXDOMClassList entry.
    public var identifiers: [String]
    public init(texts: [String], identifiers: [String]) { self.texts = texts; self.identifiers = identifiers }
}

/// Chrome exposes neither `autocomplete` nor the input type, so a card number,
/// one-time code, PIN or web terminal is recognised by its label, id or class.
/// A match denies the key and discards the burst; it never allows anything.
public enum BrowserTypingFieldRules {
    /// Every word of TextClassifier.sensitiveLabel (TextClassifier.swift:22),
    /// which MemoryCore cannot import. scripts/check_browser_boundary.py
    /// checks that this list stays a superset.
    static let classifierWords = ["password", "passcode", "passphrase", "otp", "one-time", "verification", "credit card", "card number",
        "cvv", "cvc", "iban", "routing", "account number", "social security", "passport", "api key", "secret", "contraseña",
        "mot de passe", "passwort", "验证码", "驗證碼", "密码", "密碼", "パスワード", "رمز المرور"]
    /// Substrings of the lowercased label, also read with `-`, `_`, `.` and
    /// camelCase boundaries as spaces.
    public static let phrases: [String] = classifierWords + ["one time", "security code", "expir", "mm/yy", "mm / yy", "two factor",
        "authentication code", "auth code", "access code", "sms code", "backup code", "recovery code", "confirmation code", "sort code",
        "tax id", "taxpayer", "cardholder", "name on card", "terminal", "xterm", "inputarea", "monaco", "authenticator",
        // fix/chrome-capture (QF-3): a sign-in username, even on its own (a first step before the password page).
        "username", "user name",
        // fix/chrome-capture (review X1): a wallet's or a recovery form's secret, often a text area (extra defence; the
        // form scan also runs around text areas).
        "mnemonic", "seed phrase", "recovery phrase", "recovery words", "secret phrase", "private key", "security answer"]
    /// Judged in labels only, never in the DOM id or class names: Monaco's
    /// aria-label "Editor content;Press Alt+F1 for Accessibility Options.".
    /// Draft.js names every editor `public-DraftEditor-content` (X's post,
    /// reply and message boxes), which reads the same words; that is an
    /// ordinary text box. Monaco stays refused by its classes `inputarea` and
    /// `monaco-…` too. "2-step" and "two-step" (verification codes) are
    /// judged in labels only too: hashed class names can read "… 2 step …".
    public static let labelOnlyPhrases: [String] = ["editor content", "2 step", "two step"]
    /// Whole words of any label.
    public static let labelTokens: Set<String> = ["cc", "card", "pin", "otp", "cvv", "cvc", "csc", "ssn", "tin", "mfa", "2fa", "totp",
        "iban", "exp", "mmyy",
        // fix/chrome-capture (QF-4): "Enter the 6-digit code" (a promo or zip code stays allowed).
        "digit", "digits"]
    /// Whole words of the DOM id and class names. A superset of the device
    /// harness's FieldDeny.idTokens (checked by scripts/check_browser_boundary.py).
    public static let idTokens: Set<String> = ["cc", "card", "cvc", "cvv", "csc", "exp", "otp", "code", "pin", "iban", "routing",
        "password", "passcode", "totp", "2fa", "mfa", "ssn", "xterm", "inputarea", "terminal", "monaco",
        // fix/chrome-capture (QF-3): sign-in fields by their DOM id or class.
        "username", "login", "signin", "logon", "userid"]
    public static let maxLabels = 64
    public static let maxLabelBytes = 4096

    public static func denies(_ l: BrowserTypingFieldLabels) -> Bool {
        let all = l.texts + l.identifiers
        guard all.count <= maxLabels, all.allSatisfy({ $0.utf8.count <= maxLabelBytes }) else { return true }
        return l.texts.contains { hit($0, extra: [], phrases: phrases + labelOnlyPhrases) || maskLike($0) || codeWord($0) || identityNumber($0) }
            || genericOnly(l)
            || l.identifiers.contains { hit($0, extra: idTokens, phrases: phrases) }
    }
    /// fix/chrome-capture (QF-4): a label or placeholder that is a mask of a number or code: only digits, bullets,
    /// asterisks, x's, spaces, dashes, dots and slashes, with at least 4 digits, bullets, asterisks or x's
    /// ("1234 5678 9012 3456", "••••••", "000000", "XXX-XX-XXXX", "12/26"). Conservative: "555-555-5555" or a date
    /// "01/01/2000" is refused too; "(555) 555-5555", "+1 …" and "MM/YY"-style words are not masks (letters or other marks).
    /// Read after the same compatibility mapping as `hit` (review Q4 item 2): full-width digits ("１２３４") and "＊"
    /// read as ASCII; any decimal digit counts; "∗" and "◦" are marks too.
    static func maskLike(_ raw: String) -> Bool {
        let t = normalized(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, t.count <= 64 else { return false }
        let marks: Set<Character> = ["•", "●", "∙", "·", "*", "∗", "◦", "x", "X", "_"]
        let fillers: Set<Character> = [" ", "-", ".", "/", "\u{2013}"]
        func digit(_ c: Character) -> Bool { c.unicodeScalars.count == 1 && c.unicodeScalars.first?.properties.numericType == .decimal }
        guard t.allSatisfy({ digit($0) || marks.contains($0) || fillers.contains($0) }) else { return false }
        return t.filter { digit($0) || marks.contains($0) }.count >= 4
    }
    /// fix/chrome-capture (review Q4 item 3): the label word "code" (or "codes") is a code to keep private ("Enter
    /// code", "Enter the 6-digit code", "Code") unless the word right before it names an ordinary code.
    static let ordinaryCodes: Set<String> = ["zip", "postal", "post", "promo", "coupon", "discount", "referral", "invite", "country", "area"]
    static func codeWord(_ raw: String) -> Bool {
        let words = tokens(normalized(raw))
        return words.indices.contains { i in
            ["code", "codes"].contains(words[i]) && (i == 0 || !ordinaryCodes.contains(words[i - 1]))
        }
    }
    /// The compatibility mapping without zero-width characters, as `hit` reads a label.
    static func normalized(_ raw: String) -> String {
        String(String.UnicodeScalarView(raw.precomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { ![0x200b, 0x200c, 0x200d, 0xfeff, 0x2060].contains($0.value) }))
    }
    /// fix/chrome-capture (QF-4, option a): a one-line box (a text field, a search field or an editable combo box)
    /// with no label, description or placeholder at all is refused (`field`: can't prove). Review Q4-1: a search field
    /// too (type=search is also used on sign-in and card boxes to keep autofill away). Chrome exposes neither `autocomplete`
    /// nor the input type, so an unlabelled box can be a card number, a one-time code or a password shown as text
    /// (fixture P04, P08, P12), and nothing about it proves otherwise. Codex 06:10: a text area or contenteditable box
    /// (AXTextArea) with no label is refused too (a stated loss: an unlabelled composer, fixture C03). Label texts are
    /// read after the compatibility mapping, without zero-width characters. Review Q5-1: a box counts as labelled only
    /// if some text has a letter or a digit; punctuation or emoji alone ("*", "-", "…", "🔑") is no label.
    public static func unlabelled(role: String, subrole: String, labels: BrowserTypingFieldLabels) -> Bool {
        guard ["AXTextField", "AXComboBox", "AXTextArea"].contains(role) else { return false }
        return !labels.texts.contains { normalized($0).contains { $0.isLetter || $0.isNumber } }
    }
    /// Codex 06:10, widened by review Q5-3: a box whose label texts together say no more than a generic noun (number,
    /// value, ID, key, token, input, answer, entry; plurals, "No.", "Nr.", "Num", "#", "Nº", and Número, Numéro, Nummer,
    /// Valor, Valeur, Wert, номер, 番号, 号码), with only filler words, a bare index or a sample digit beside it ("Enter
    /// a value", "Value 1", "Number #2", "Number" with the placeholder "e.g. 42"), is a suspicious code field:
    /// sensitiveField. Scoped: any other word keeps the other rules ("Phone number", "Order number", "Value (USD)",
    /// "Number of guests", "Street number", "Name" beside "Value"). Stated costs: "Your answer" on a quiz or a Q&A
    /// site's answer composer, a "Key" box in a key/value editor, boxes labelled only "Input", "ID" or "Entry".
    static let genericNouns: Set<String> = ["number", "numbers", "value", "values", "no", "nr", "num", "nums", "id", "ids", "key", "keys",
        "token", "tokens", "input", "answer", "entry", "numero", "numeros", "nummer", "nummern", "valor", "valores", "valeur", "valeurs",
        "wert", "werte", "номер", "番号", "号码", "號碼"]
    static let fillerWords: Set<String> = ["enter", "a", "an", "the", "your", "type", "here", "please", "e", "g", "eg", "ex", "example", "i"]
    /// Identity numbers named by a phrase (review Q5-3, widened by Q6), matched as whole words in order, after folding
    /// diacritics ("Sécurité sociale"); a one-word national ID name or a German compound stem anywhere in a label.
    /// Refusal-only costs: "User ID", "Customer ID" boxes; "nino" is also Spanish for "child" (folded "niño").
    static let identityPhrases: [[String]] = [["id", "number"], ["national", "id"], ["tax", "number"], ["social", "insurance", "number"],
        ["national", "insurance", "number"], ["license", "number"], ["licence", "number"], ["personal", "number"],
        // Review Q6 (Q5 holes): more identity numbers, "no." forms and account IDs; folded foreign phrases.
        ["identification", "number"], ["identity", "number"], ["personal", "id"], ["id", "no"], ["license", "no"], ["licence", "no"],
        ["tax", "no"], ["personal", "no"], ["user", "id"], ["login", "id"], ["member", "id"], ["customer", "id"],
        ["securite", "sociale"], ["seguridad", "social"], ["codice", "fiscale"]]
    /// Review Q6: one-word national ID names ("sin" is left out: an ordinary word in Spanish).
    static let identityWords: Set<String> = ["personnummer", "aadhaar", "nino", "tfn", "bsn", "nric", "pesel", "curp", "cpf"]
    /// Review Q6: compound stems (German writes them into one word: "Sozialversicherungsnummer", "Steuernummer").
    static let identityStems = ["sozialversicherung", "steuernummer", "personnummer"]
    /// A label's words for the generic rules: the compatibility mapping, diacritics folded, "#" and "№" read as "number".
    static func genericWordsOf(_ raw: String) -> [String] {
        let s = normalized(raw).replacingOccurrences(of: "#", with: " number ").replacingOccurrences(of: "\u{2116}", with: " number ")
        return tokens(s.folding(options: [.diacriticInsensitive], locale: nil))
    }
    static func genericOnly(_ l: BrowserTypingFieldLabels) -> Bool {
        let texts = l.texts.map(genericWordsOf).filter { !$0.isEmpty }
        let generic: (String) -> Bool = { genericNouns.contains($0) || fillerWords.contains($0) || $0.allSatisfy(\.isNumber) }
        return !texts.isEmpty && texts.allSatisfy { $0.allSatisfy(generic) } && texts.contains { $0.contains(where: genericNouns.contains) }
    }
    static func identityNumber(_ raw: String) -> Bool {
        let w = genericWordsOf(raw)
        if w.contains(where: { identityWords.contains($0) || identityStems.contains(where: $0.contains) }) { return true }
        return identityPhrases.contains { p in w.count >= p.count && (0...(w.count - p.count)).contains { Array(w[$0..<($0 + p.count)]) == p } }
    }
    static func hit(_ raw: String, extra: Set<String>, phrases: [String]) -> Bool {
        let s = String(String.UnicodeScalarView(raw.precomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { ![0x200b, 0x200c, 0x200d, 0xfeff, 0x2060].contains($0.value) }))
        let lower = s.lowercased()
        let words = tokens(s)
        let spaced = words.joined(separator: " ")
        if phrases.contains(where: { lower.contains($0) || spaced.contains($0) }) { return true }
        if words.contains(where: { labelTokens.contains($0) || extra.contains($0) }) { return true }
        // `tokens` splits "2FA" into "2" and "fa" (a capital after a digit
        // starts a word); a digit-only word is read joined to the next one too.
        return zip(words, words.dropFirst()).contains { d, w in
            d.allSatisfy(\.isNumber) && (labelTokens.contains(d + w) || extra.contains(d + w))
        }
    }
    /// Splits `ccNumber`, `cc-exp`, `one_time_code` into lowercase words
    /// (the device harness's FieldDeny.tokens).
    public static func tokens(_ s: String) -> [String] {
        var out: [String] = [], cur = ""
        var prevLower = false
        for ch in s {
            if ch.isLetter || ch.isNumber {
                if ch.isUppercase && prevLower { out.append(cur); cur = "" }
                cur.append(Character(ch.lowercased()))
                prevLower = ch.isLowercase || ch.isNumber
            } else {
                if !cur.isEmpty { out.append(cur); cur = "" }
                prevLower = false
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out.filter { !$0.isEmpty }
    }
}

/// Message composers on sites outside the categories (review F1): a site's
/// own chat drawer or a support chat on an "Other websites" page, or an
/// email's recipients and subject. Read from the same transient labels as
/// `BrowserTypingFieldRules` (AXTitle, AXDescription, AXPlaceholderValue, the
/// DOM id and classes); Chrome's Accessibility tree gives a composer no role
/// of its own (it is an AXTextArea or AXTextField like any box), so its
/// label, placeholder, id and classes are what can be read. A match only
/// moves the field into Messages and email (on unless turned off); it never
/// allows anything. Words and phrases match whole words ("data message" is
/// not "a message"); an unlisted AI chat box that reads like a message box
/// ("Type your message here") counts as one, the stricter reading.
public enum BrowserTypingComposerRules {
    /// A whole label, trimmed, with trailing dots, colons and ellipses dropped
    /// ("Message", Messenger's "Aa", "Reply", an email's "Cc" or "Subject").
    public static let labels: Set<String> = ["message", "messages", "aa", "reply", "chat", "compose", "dm", "sms", "text message",
                                             "send message", "write message", "type message", "new message",
                                             "cc", "bcc", "subject", "add a subject", "recipients", "to recipients", "add recipients"]
    /// Label beginnings: "Message #general", "Message @sam", "Reply to Sam", "Chat with support".
    public static let prefixes = ["message ", "reply to ", "chat with ", "write to ", "send to ", "text to "]
    /// Whole-word phrases anywhere in a label ("Type a message", "Write a
    /// message…", "Start a new message", "Compose your message", "Post your
    /// reply", "Type message here", "Send an encrypted message"), with the
    /// same in French and Dutch, which say "message" and "bericht" too.
    public static let phrases = ["a message", "new message", "your message", "direct message", "private message", "text message",
                                 "chat message", "message body", "message text", "your reply", "a reply", "send message", "message to",
                                 "type message", "enter message", "write message", "encrypted message", "start a conversation",
                                 "un message", "votre message", "ton message", "nouveau message", "een bericht", "nieuw bericht",
                                 "je bericht", "uw bericht"]
    /// Whole words meaning "message" in other languages ("Escribe un mensaje",
    /// "Nachricht schreiben", "Scrivi un messaggio", "Написать сообщение").
    public static let words: Set<String> = ["mensaje", "mensajes", "mensagem", "mensagens", "nachricht", "nachrichten", "messaggio",
                                            "messaggi", "wiadomość", "wiadomosc", "wiadomości", "сообщение", "сообщения", "сообщений",
                                            "повідомлення", "mesaj", "mesajı", "pesan"]
    /// Scripts written without spaces: "message" anywhere in the label
    /// ("メッセージを入力", "输入消息", "訊息", "메시지 입력", "私信").
    public static let scriptWords = ["メッセージ", "消息", "讯息", "訊息", "메시지", "私信"]
    /// Whole words of the DOM id and class names ("msg-form__contenteditable",
    /// "chat-input", "dm-composer", "message-input", "messageInput", Roundcube's "composebody").
    public static let idTokens: Set<String> = ["composer", "compose", "chat", "chatbox", "dm", "dms", "messenger", "msg", "msgs",
                                               "reply", "inbox", "conversation", "sms", "message", "messages", "messageinput",
                                               "messagebox", "composebody"]

    public static func composer(_ l: BrowserTypingFieldLabels) -> Bool {
        l.texts.contains(where: labelled) || l.identifiers.contains { BrowserTypingFieldRules.tokens(clean($0)).contains(where: idTokens.contains) }
    }
    static func labelled(_ raw: String) -> Bool {
        let s = clean(raw).lowercased()
        let tokens = BrowserTypingFieldRules.tokens(s)
        let spaced = tokens.joined(separator: " ")
        var whole = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = whole.last, [".", "…", ":"].contains(last) { whole.removeLast() }
        whole = whole.trimmingCharacters(in: .whitespacesAndNewlines)
        if labels.contains(whole) || labels.contains(spaced) { return true }
        if prefixes.contains(where: { whole.hasPrefix($0) }) { return true }
        let padded = " " + spaced + " "
        if phrases.contains(where: { padded.contains(" " + $0 + " ") }) { return true }
        if tokens.contains(where: words.contains) { return true }
        return scriptWords.contains { whole.contains($0) }
    }
    private static func clean(_ raw: String) -> String {
        String(String.UnicodeScalarView(raw.precomposedStringWithCompatibilityMapping.unicodeScalars
            .filter { ![0x200b, 0x200c, 0x200d, 0xfeff, 0x2060].contains($0.value) }))
    }
}

// MARK: - Input: quiet period after focus-changing input

public enum BrowserTypingInput {
    /// Return, keypad Enter, Tab, Escape, arrows, Home/End/Page Up/Page Down,
    /// or any Command/Control/Option chord. Clicks are reported separately.
    public static func disruptive(keyCode: Int64, command: Bool, control: Bool, option: Bool) -> Bool {
        command || control || option || [36, 76, 48, 53, 123, 124, 125, 126, 115, 119, 116, 121].contains(keyCode)
    }
    /// UNCONFIRMED and not wired: keys from the keyboard are expected to carry
    /// source process ID 0 (`kCGEventSourceUnixProcessID`); keys posted by an
    /// app (a launcher or password manager typing for the user) carry that
    /// app's process ID. To be checked on device before it is used to drop keys.
    public static func hardwareSource(sourcePID: Int64) -> Bool { sourcePID == 0 }
}

// MARK: - Accessibility and environment seams

/// Metadata-only AX seam. Production uses AXUIElement + CFEqual.
/// `role`/`subrole` return "" when unsupported and nil on error.
/// `windows` is Chrome's AXWindows (geometry is read from it, never content).
/// `title` is asked only of the focused window, `url` only of the one
/// AXWebArea and `fieldLabels` only of the focused field, and only after every
/// Chrome window answered "normal" and every Accessibility window was matched
/// to a listed window.
/// Fixed predicates for a metadata-only page search. No arbitrary key or text enters the witness.
public enum BrowserFormSearch: Equatable { case textFields; case revealControls(String) }

public struct ChromeAXAccess<Node> {
    public var frontmostPID: () -> Int32?
    /// System-wide focused application (Spotlight takes focus while Chrome stays frontmost).
    public var systemFocusedPID: () -> Int32?
    public var secureInput: () -> Bool
    public var focusedWindow: () -> Node?
    public var windows: () -> [Node]?
    public var focusedElement: () -> Node?
    public var owner: (Node) -> Int32?
    public var role: (Node) -> String?
    public var subrole: (Node) -> String?
    public var parent: (Node) -> Node?
    public var frame: (Node) -> ChromeBounds?
    public var minimized: (Node) -> Bool?
    public var title: (Node) -> String?
    public var url: (Node) -> String?
    public var fieldLabels: (Node) -> BrowserTypingFieldLabels?
    public var equal: (Node, Node) -> Bool
    /// Chrome's AXEditableAncestor: the text field or contenteditable root a
    /// node types into, itself for a text box. nil when unsupported or unread.
    /// The regular join asks of AXComboBox to distinguish an editable search box from a select-only drop-down.
    /// C1 QA's gated page search also checks the focused sentinel and an AXGroup editable root.
    public var editableAncestor: (Node) -> Node?
    /// fix/chrome-capture (the Post gesture, `BrowserTypingJoin.submitControl`): the element of Chrome's application at
    /// a global point (Accessibility's hit test), whether a control is enabled (AXEnabled), and a control's names
    /// (AXTitle and AXDescription; nil when either can't be read). Asked only after a click join proved the page.
    public var elementAt: (Double, Double) -> Node?
    public var enabled: (Node) -> Bool?
    public var controlNames: (Node) -> [String]?
    /// Form scans can check their deadline between the title and description reads.
    /// nil keeps simple fixture adapters compatible; the caller still checks time before and after names.
    public var formControlNames: ((Node, () -> Bool) -> [String]?)? = nil
    /// fix/chrome-capture (QF-11, QF-3): a node's children (AXChildren), for the field's form scan
    /// (`BrowserFormScan`); nil when they can't be read.
    public var children: (Node) -> [Node]?
    /// C1 option 1: transient element references, scoped to the proven page; nil means unsupported/error.
    public var formSearch: (Node, BrowserFormSearch, Int) -> [Node]?
    /// fix/chrome-large-pages (owner-approved 2026-10-02): ON in production and QA. A walk that runs out of its node
    /// budget (`exhausted`) is answered by the bounded page search (`BrowserFormScan.search`); every other walk answer
    /// (password, reveal, unreadable incl. the child cap, late) is never downgraded, and a search that can't finish,
    /// finds a secure field or a reveal control, or runs late still refuses. Was: OFF (C-8), so a deep field on any page
    /// larger than the walk's 64 nodes (Google, X, Gmail, Reddit) was refused. C-8's live hidden-case evidence is
    /// still open; checks may switch this off to reproduce the old refusal.
    public var formSearchRecoveryEnabled = true
    public init(frontmostPID: @escaping () -> Int32?, systemFocusedPID: @escaping () -> Int32?, secureInput: @escaping () -> Bool,
                focusedWindow: @escaping () -> Node?, windows: @escaping () -> [Node]?, focusedElement: @escaping () -> Node?,
                owner: @escaping (Node) -> Int32?, role: @escaping (Node) -> String?, subrole: @escaping (Node) -> String?,
                parent: @escaping (Node) -> Node?, frame: @escaping (Node) -> ChromeBounds?, minimized: @escaping (Node) -> Bool?,
                title: @escaping (Node) -> String?, url: @escaping (Node) -> String?,
                fieldLabels: @escaping (Node) -> BrowserTypingFieldLabels?, equal: @escaping (Node, Node) -> Bool,
                editableAncestor: @escaping (Node) -> Node? = { _ in nil },
                elementAt: @escaping (Double, Double) -> Node? = { _, _ in nil }, enabled: @escaping (Node) -> Bool? = { _ in nil },
                controlNames: @escaping (Node) -> [String]? = { _ in nil }, children: @escaping (Node) -> [Node]? = { _ in nil },
                formSearch: @escaping (Node, BrowserFormSearch, Int) -> [Node]? = { _, _, _ in nil }) {
        self.frontmostPID = frontmostPID; self.systemFocusedPID = systemFocusedPID; self.secureInput = secureInput
        self.focusedWindow = focusedWindow; self.windows = windows; self.focusedElement = focusedElement; self.owner = owner
        self.role = role; self.subrole = subrole; self.parent = parent; self.frame = frame; self.minimized = minimized
        self.title = title; self.url = url; self.fieldLabels = fieldLabels; self.equal = equal
        self.editableAncestor = editableAncestor
        self.elementAt = elementAt; self.enabled = enabled; self.controlNames = controlNames
        self.children = children; self.formSearch = formSearch
    }
    /// Names for form scans use the deadline seam supplied by the adapter.
    public func controlNamesForForm(_ node: Node, late: () -> Bool) -> [String]? {
        if let formControlNames { return formControlNames(node, late) }
        return controlNames(node)
    }
    /// A text box website typing may attribute keys to: a text field, a text
    /// area (a contenteditable root is one, whatever its ARIA role), or an
    /// editable combo box (search and autocomplete boxes) that is its own
    /// editable root. A label is never needed; the secure checks stay with the
    /// caller. One list with `WebTypingGate.roles`.
    public func textBox(_ node: Node, role: String) -> Bool {
        switch role {
        case "AXTextField", "AXTextArea": return true
        case "AXComboBox": return editableAncestor(node).map { equal($0, node) } == true
        default: return false
        }
    }
}
public struct ChromeJoinEnvironment {
    public var now: () -> UInt64
    /// Private build + the separate browser-typing consent + not paused.
    public var enabled: () -> Bool
    /// Signature, versions and instance count; read once per join.
    public var target: () -> ChromeTargetFacts?
    /// The reader's Automation check with its default request:false; never prompts. Once per join.
    public var automationPermitted: (Int32) -> Bool
    /// Cheap re-check that the target was not relaunched during the join (pid + launch date).
    public var launchIdentity: (Int32) -> String?
    public init(now: @escaping () -> UInt64, enabled: @escaping () -> Bool, target: @escaping () -> ChromeTargetFacts?,
                automationPermitted: @escaping (Int32) -> Bool, launchIdentity: @escaping (Int32) -> String?) {
        self.now = now; self.enabled = enabled; self.target = target; self.automationPermitted = automationPermitted
        self.launchIdentity = launchIdentity
    }
}

// MARK: - Window accounting

public enum ChromeWindowMatching {
    /// True when every Accessibility frame can be paired with a different
    /// Apple Events bounds (a one-to-one matching; augmenting paths). A window
    /// Accessibility shows but Apple Events did not list (an Incognito window
    /// that is opening or closing, or a second process) leaves one unpaired.
    public static func coversAll(_ axFrames: [ChromeBounds], _ aeBounds: [ChromeBounds]) -> Bool {
        guard axFrames.count <= aeBounds.count else { return false }
        var owner = [Int?](repeating: nil, count: aeBounds.count)
        func augment(_ i: Int, _ seen: inout [Bool]) -> Bool {
            for j in aeBounds.indices where !seen[j] && axFrames[i].matches(aeBounds[j]) {
                seen[j] = true
                if let k = owner[j] { if !augment(k, &seen) { continue } }
                owner[j] = i
                return true
            }
            return false
        }
        for i in axFrames.indices {
            var seen = [Bool](repeating: false, count: aeBounds.count)
            guard augment(i, &seen) else { return false }
        }
        return true
    }

    /// fix/chrome-capture (QF-10): whether a window's Accessibility title belongs to the Apple Events window
    /// `name` (the active tab's title). Chrome's AXTitle is the name alone, or the name followed by
    /// " - Google Chrome" (or an en dash), optionally followed by " - <profile>" when more than one Chrome profile
    /// exists. Nothing else: the remainder after the name must be empty or exactly that suffix and profile tail. A
    /// page whose own title contains " - Google Chrome" can make two windows match; the join then refuses both
    /// (`ambiguousWindow`), because it never prefers one of several matches.
    /// Diagnostics only: how the AX title relates to the candidates' names (the first that matches decides).
    public enum TitleShape: String, CaseIterable, Sendable { case exact, suffix, profile, none }
    public static func shape(axTitle: String, names: [String]) -> TitleShape {
        guard let name = names.first(where: { titleMatches(axTitle: axTitle, aeName: $0) }) else { return .none }
        if axTitle == name || axTitle == baseName(name) { return .exact }
        return (afterApp(axTitle: axTitle, aeName: baseName(name)) ?? "").isEmpty ? .suffix : .profile
    }
    public static func titleMatches(axTitle: String, aeName: String) -> Bool {
        if axTitle == aeName { return true }
        // fix/chrome-x (harness, owner's Chrome 154, 10-03): while a tab plays sound Chrome's Apple Events window name
        // ends with " \u{1F50A}" (a speaker) that the Accessibility title doesn't have ("<title> - YouTube \u{1F50A}" vs
        // "<title> - YouTube - Google Chrome - <profile>"), so every page playing sound (an X video post) matched no
        // window. Only one trailing indicator from `chromeNameIndicators` is set aside.
        let name = baseName(aeName)
        if name != aeName, axTitle == name { return true }
        guard let rest = afterApp(axTitle: axTitle, aeName: name) else { return false }
        if rest.isEmpty { return true }
        for tail in [" - ", " \u{2013} "] where rest.hasPrefix(tail) {
            let profile = rest.dropFirst(tail.count)
            if !profile.trimmingCharacters(in: .whitespaces).isEmpty, profile.utf8.count <= 256,
               !profile.contains(where: { $0.isNewline }) { return true }
        }
        return false
    }
    /// What follows "<name>[<tab states>] - Google Chrome" in the AX title, or nil when the title doesn't have that shape.
    static func afterApp(axTitle: String, aeName: String) -> Substring? {
        guard axTitle.hasPrefix(aeName) else { return nil }
        var rest = axTitle.dropFirst(aeName.count)
        // fix/chrome-x (live test 10-03, x.com reply: every join refused `window`): Chrome's accessible window title is
        // the active tab's ACCESSIBLE label, which appends the tab's state to the page title: " - Audio playing",
        // " - Pinned", " - High memory usage - 1.2 GB" and the rest of `chromeTabStates` (Chrome 154's en strings,
        // `IDS_TAB_AX_LABEL_*`). The Apple Events name has none of them. A video post on X (audio, a heavy tab) made
        // the reply's window match no name. Only these fixed annotations, at most a few, are skipped; the page title
        // must still equal the name exactly, and two windows that both match are still refused (`ambiguousWindow`).
        for _ in 0..<maxTabStates {
            guard let state = chromeTabState(prefixOf: rest) else { break }
            rest = rest.dropFirst(state)
        }
        for dash in [" - ", " \u{2013} "] {
            let head = dash + "Google Chrome"
            if rest.hasPrefix(head) { return rest.dropFirst(head.count) }
        }
        return nil
    }
    static let maxTabStates = 4
    /// Indicators Chrome appends to a window's Apple Events name for its tab's media state (a speaker while sound plays).
    public static let chromeNameIndicators: [String] = ["\u{1F50A}", "\u{1F509}", "\u{1F508}", "\u{1F507}", "\u{1F534}"]
    /// The Apple Events name without one trailing media indicator (" \u{1F50A}"), or the name as it is.
    public static func baseName(_ aeName: String) -> String {
        for i in chromeNameIndicators where aeName.hasSuffix(" " + i) && aeName.count > i.count + 1 { return String(aeName.dropLast(i.count + 1)) }
        return aeName
    }
    /// Chrome's tab state annotations as its accessible tab label writes them after the title (en).
    public static let chromeTabStates: [String] = [
        "Camera and microphone recording", "Microphone recording", "Camera recording", "Tab content shared",
        "Video playing in picture-in-picture mode", "Audio playing", "Audio muted", "Bluetooth device connected",
        "Bluetooth scan active", "USB device connected", "HID device connected", "Serial port connected", "Network error",
        "Crashed", "Desktop content shared", "VR presenting to headset", "Pinned", "Inactive tab"]
    /// The length of the one state annotation (" - <state>", or a memory one with its size) at the start of `s`, or nil.
    static func chromeTabState(prefixOf s: Substring) -> Int? {
        guard s.hasPrefix(" - ") else { return nil }
        let body = s.dropFirst(3)
        for state in chromeTabStates where body.hasPrefix(state) {
            let after = body.dropFirst(state.count)
            if after.isEmpty || after.hasPrefix(" - ") || after.hasPrefix(" \u{2013} ") { return 3 + state.count }
        }
        // " - Memory usage - 312 MB", " - High memory usage - 1.2 GB", " - 1.2 GB freed up" (sizes as Chrome formats them).
        let size = #"[0-9][0-9.,]{0,12} (?:B|KB|MB|GB|TB)"#
        for pattern in ["^(?:High memory usage|Memory usage) - " + size, "^" + size + " freed up"] {
            if let r = body.range(of: pattern, options: .regularExpression) {
                let after = body[r.upperBound...]
                if after.isEmpty || after.hasPrefix(" - ") || after.hasPrefix(" \u{2013} ") { return 3 + body.distance(from: body.startIndex, to: r.upperBound) }
            }
        }
        return nil
    }
}

// MARK: - Join result

/// Internal only: never persist or display a denial (the reason would show
/// when an Incognito window was open). Surfaces show "capturing on <site>" or nothing.
public enum BrowserTypingDenial: String, Error, Sendable, CaseIterable {
    case disabled, untrustedTarget, noPermission, notFocused, windowList, notNormal, window, unlistedWindow, ambiguousWindow,
         field, sensitiveField, frame, url, blockedSite, changed, timeout
    /// The keyboard input source is not a direct layout (an input method
    /// composes the text): the key is unproven, as in native typing. Set by
    /// the owner build's website route before any join read.
    case inputMethod
}
/// Origin-only proof. No titles, full URLs, names, labels or field contents.
public struct BrowserTypingJoinProof: Equatable, Sendable {
    public let origin: String
    public let windowID: String
    public let tabID: String
    /// Every Chrome window ID, front to back, when the proof was taken.
    public let windowList: [String]
    public let documentID: String
    public let focusID: String
    public let targetIdentity: String
    public let role: String
    public let subrole: String
    public let checkedAt: UInt64
    /// summaries/v3: the field class and a chat composer's place, derived from the labels read in step 13 (the labels
    /// themselves are never kept). Metadata for the typed unit's send facts; not part of the burst's identity.
    public var sendField = ""
    public var sendPlace = ""
    /// fix/typing-e2e (L5): the page's title exactly as Chrome page history saves it for this page
    /// (`WebTypingTitle.clean`), "" where page history saves the site only (search, email and chat pages) or the title
    /// can't be used. Metadata for the typed row's place, so the typing joins the page's moment; not part of the
    /// burst's identity (a title that changes while typing never splits a unit).
    public var pageTitle = ""
    /// fix/chrome-x (compose signals, `BrowserComposeSignals`): the page's route reduced to the compose kinds
    /// (`BrowserComposeRoute.path`: "/<handle>/status/_", "/compose/post", "/r/<sub>/comments/_", or ""), and the
    /// composer's reply markers from the labels step 13 read ("Post your reply", "Replying to @h"; nothing else of the
    /// labels). Memory only; metadata for the compose model, not part of the burst's identity.
    public var composeRoute = ""
    public var replyLabels: [String] = []
    /// Q-4 ephemeral observation starts, never persisted. A title match proves agreement, not freshness.
    public var titleObservedAt: UInt64? = nil
    public var axURLObservedAt: UInt64? = nil
    public var leanRead = false
    /// Recent titles become site-only. Lean URL admission needs a post-anchor settled observation; full/sync
    /// reads retain their fresh AE URL + AX URL checks and do not wait on main for AX URL settlement.
    public func settledMetadata(anchor: UInt64, requireURL: Bool = true) -> BrowserTypingJoinProof? {
        let floor = anchor &+ ChromeBracketTiming.metadataSettleNanoseconds
        if requireURL && leanRead && axURLObservedAt.map({ $0 >= floor }) != true { return nil }
        var p = self
        if titleObservedAt.map({ $0 >= floor }) != true { p.pageTitle = "" }
        return p
    }
    /// A light per-key check (`BrowserTypingJoin.light`) of the field a full
    /// join allowed less than `proofTTL` ago. It admits a key of a burst a full
    /// join started; it never starts a burst, saves, settles or proves a click.
    public var light = false
    /// QF-17 (bracketed design only): the read this proof came from, with every fact's digest and observation
    /// times, for the bracket engine (`ChromeBracketEngine`). nil for the synchronous design and click joins.
    /// Not part of equality or the burst's identity.
    public var bracket: ChromeReadRecord? = nil
    /// Same window, tab, page, field and window list: the same burst.
    public func sameBurst(as other: BrowserTypingJoinProof) -> Bool {
        origin == other.origin && windowID == other.windowID && tabID == other.tabID && windowList == other.windowList
            && documentID == other.documentID && focusID == other.focusID && targetIdentity == other.targetIdentity
            && role == other.role && subrole == other.subrole
    }
}
public enum BrowserTypingJoinResult: Equatable, Sendable {
    case allowed(BrowserTypingJoinProof)
    case denied(BrowserTypingDenial)
    public var proof: BrowserTypingJoinProof? { if case .allowed(let p) = self { return p }; return nil }
    public var denial: BrowserTypingDenial? { if case .denied(let d) = self { return d }; return nil }
}

// MARK: - The join

public final class BrowserTypingJoin<Node> {
    private struct Read {
        var ids: [String]
        var axFrames: [ChromeBounds]
        var bounds: [ChromeBounds]
        var candidates: [Int]
        var names: [String]        // transient, compared only
        var windowID: String
        var tabID: String
        var url: String            // transient, compared and evaluated only
        var axURL: String          // transient
        var frame: ChromeBounds
        var titleObservedAt: UInt64
        var title: String          // transient
        var pageName = ""          // transient: the matched Apple Events name (the tab's title, no Chrome suffix)
        var window: Node
        var focus: Node
        var webArea: Node
        var chain: [Node]
        var role: String
        var subrole: String
        var windows: [Node]
        var sendField = ""
        var sendPlace = ""
        var composeRoute = ""
        var replyLabels: [String] = []
    }
    typealias Page = (target: String, windowID: String, tabID: String, document: Int, window: Node, webArea: Node, focus: Node, documentID: String, focusID: String)
    /// The page (and focus) the last allowed join proved. A denied join forgets it.
    var previous: Page?
    /// Review G12, round 1: the page a full join forgot because it found focus
    /// on something that isn't a text field (`.field`: Tab to a Send button).
    /// Only the very next join may use it, and only a click join (`anyFocus`,
    /// the settle's): that click join is then compared with the page the
    /// words were typed in, not with nothing. Every check before the focus
    /// check had passed, and the click join repeats all of them (both reads,
    /// the same window and web area objects, the same document), so this
    /// never proves a page the click join didn't find. Any other join, a
    /// denied click join and `invalidate` clear it.
    var departedPage: Page?
    /// The last allowed full join of a text field (never a click join): what
    /// the light per-key check compares with. Memory only, and only while it
    /// is younger than `proofTTL`; a denied join, a click join or
    /// `invalidate` clears it. The address is kept here only for that second,
    /// to ask the site rules again.
    struct Anchor {
        let pid: Int32
        let ids: [String]
        let windows: [Node]
        let window: Node
        let focus: Node
        let parent: Node
        let webArea: Node
        let url: String
        let axURL: String
        let proof: BrowserTypingJoinProof
    }
    var anchor: Anchor?
    /// fix/chrome-capture: the text field the last allowed full join proved (never a click or light join), with its
    /// ancestry up to the window as read then. Memory only. Usable (`fieldTrail`) only while the page it was on is
    /// still the page the last allowed join proved: a denied join (`invalidate`) or another page makes it stale.
    private var trail: BrowserFieldTrail<Node>?
    var fieldTrail: BrowserFieldTrail<Node>? {
        guard let t = trail, let p = previous, p.documentID == t.documentID, p.target == t.targetIdentity,
              p.windowID == t.windowID, p.tabID == t.tabID else { return nil }
        return t
    }
    /// fix/chrome-x (compose signals): the composer the last allowed full join proved, read again after a send gesture
    /// (`ComposeSend.confirmChecks`): is the field still in the page where it was typed, does it still have focus, is
    /// its value empty (`value`, the host's AXValue read of that field, asked only while it is in the page), and the
    /// page's route (the web area's AXURL, reduced at once by `BrowserComposeRoute.path`; the address is never kept).
    /// nil when no full join proved a field. Accessibility only, no Apple Event; nothing here is kept.
    public func composeSnapshot(accessibility ax: ChromeAXAccess<Node>, value: (Node) -> String?) -> BrowserComposeSnapshot? {
        guard let t = trail else { return nil }
        let parent = ax.parent(t.focus)
        let present = t.chain.count > 1 && parent.map { ax.equal($0, t.chain[1]) } == true && ax.role(t.focus) != nil
        let focused = present && ax.focusedElement().map { ax.equal($0, t.focus) } == true
        let empty = present ? value(t.focus).map { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } : nil
        let url = ax.url(t.webArea)
        return BrowserComposeSnapshot(fieldPresent: present, fieldFocused: focused, valueEmpty: empty,
                                      origin: url.flatMap { BrowserTypingSites.origin($0) } ?? "",
                                      path: url.map { BrowserComposeRoute.path(url: $0) } ?? "", urlRead: url != nil)
    }
    /// QF-11: the last few focused elements a join found secure (a password field). A later join that finds one of
    /// them focused and no longer secure (a "show password" toggle made it a text field) denies it. Memory only.
    var secureFocus: [Node] = []
    func noteSecureFocus(_ ax: ChromeAXAccess<Node>) {
        guard let f = ax.focusedElement(),
              [ax.role(f), ax.subrole(f)].contains(where: { $0?.lowercased().contains("secure") == true }),
              !secureFocus.contains(where: { ax.equal($0, f) }) else { return }
        secureFocus.append(f)
        if secureFocus.count > 8 { secureFocus.removeFirst() }
    }
    /// Codex 07:10 (field hold): the text box the last full join refused as `field` after its form scan returned (the
    /// scan couldn't finish: `exhausted` or `unreadable`; or it was clear and the box has no label), with its window and
    /// Chrome's pid as read then. Not a timeout (`late`), labels that can't be read or focus off any text box. Memory only; never a label, an address or a value. Any other join, a denied join of anything else and
    /// `invalidate` forget it. Only `holdsRefusedBox` reads it, and only to keep a refusal.
    private(set) var heldBox: (pid: Int32, window: Node, focus: Node)?
    /// fix/chrome-x: the window, field and window title in focus when a full join refused the page for a reason in
    /// `BrowserTypingBurst.episodeDenials` (the window match, an iframe, the address; only once it had read the title). While they
    /// stay the same (`holdsRefusedBox`), the burst drops plain keys unread instead of joining again. Memory only.
    /// The window title is kept only as an in-memory hash (never the text), and only after this join had already read it.
    private(set) var heldEpisode: (pid: Int32, window: Node, focus: Node, titleHash: Int)?
    /// fix/chrome-x: the window and title hash step 9 read (nil when the join refused before reading any title).
    private var episodeTitle: (window: Node, titleHash: Int)?
    /// The box a read of the join in progress refused as `field` (`heldBox` after the join).
    var boxRefusal: (pid: Int32, window: Node, focus: Node)?   // QF-17: set by the bracketed read too
    /// QF-17: which design this join runs (`ChromeJoinDesign.current` when made).
    public let design: ChromeJoinDesign
    public init(design: ChromeJoinDesign = ChromeJoinDesign.current) { self.design = design }
    public func invalidate() { previous = nil; anchor = nil; departedPage = nil; heldBox = nil; heldEpisode = nil }

    /// Codex 07:10 (field hold): whether focus is still in the box the last full join refused as `field`, in the same
    /// window, with Chrome frontmost and focused and no secure input. Reads only which app, window and element have
    /// focus: no role, label, address, page or value, and no Apple Event. Deny-only: `true` keeps the refusal (the
    /// key is dropped unread, with no join); `false` (focus left it) forgets the box; nil: no box is held (nothing
    /// is read, and the full join decides).
    public func holdsRefusedBox(accessibility ax: ChromeAXAccess<Node>) -> Bool? {
        if heldBox == nil, let h = heldEpisode {
            // fix/chrome-x: the same window, field and window title. Anything else (a new page, a retitled tab, focus
            // elsewhere) ends the episode with no hold (nil): the full join decides this key, as it did before the hold.
            guard focused(ax, h.pid), let window = ax.focusedWindow(), ax.equal(window, h.window),
                  let focus = ax.focusedElement(), ax.equal(focus, h.focus), ax.title(window)?.hashValue == h.titleHash else { heldEpisode = nil; return nil }
            return true
        }
        guard let h = heldBox else { return nil }
        guard focused(ax, h.pid), let window = ax.focusedWindow(), ax.equal(window, h.window),
              let focus = ax.focusedElement(), ax.equal(focus, h.focus) else { heldBox = nil; return false }
        return true
    }

    /// `sites` is the person's website choices (categories and "Other
    /// websites"), asked of the full address once, with the block lists,
    /// before the confirming read. `field` is asked of the address and the
    /// focused field's labels in both reads (a message composer on a site
    /// outside the categories follows Messages and email). Deny-only; the
    /// address and the labels are never kept.
    ///
    /// `anyFocus` (the click join: at a click or a chorded Return,
    /// `BrowserTypingBurst.pointerDown`, and at the settle after a full join
    /// denied `.field`, `BrowserTypingBurst.resolveParked`):
    /// every window, page and site check is the same, but focus may be on any
    /// element of the page's one web area (a Send button, a link, another
    /// field), because a click may already have moved it there. Its labels
    /// are not read. Such a proof never admits a key: it only proves the page
    /// and window list the unfinished text was typed in are unchanged.
    ///
    /// A denied join forgets the page. One exception (review G12, round 1):
    /// a full join denied `.field` keeps the page it replaced for the next
    /// join if, and only if, that is a click join (`departedPage`), so the
    /// settle's click join after it (Tab to a button) can prove the same page.
    ///
    /// A click join refused for anything but privacy (a timeout, a window or
    /// page read that failed, focus elsewhere: not `forgetsPageWhenClickDenied`)
    /// leaves the page the last allowed join proved (gold/r2-typing,
    /// golden 5 G12: Command-Return with focus kept in the field, its click
    /// join timed out once, and the settle's full join, which allowed the same
    /// field, found a page it no longer knew, so the words were dropped; before
    /// the chorded Return took a click join they were saved). It proves
    /// nothing: the next full join repeats every read, and names the page the
    /// same only for the same Chrome launch, window, tab, address, window and
    /// page objects. Incognito or Guest, a blocked site, typing off and a
    /// secure focus forget it, as before; the light check's field is forgotten
    /// either way (the next key takes a full join).
    public func join(environment e: ChromeJoinEnvironment, appleEvents ae: (ChromeJoinRequest) -> ChromeJoinReply?,
                     accessibility ax: ChromeAXAccess<Node>, blockList: BrowserTypingBlockList,
                     alwaysBlocked: [String] = PrivacySettings.sensitiveDomains,
                     sites: (String) -> Bool = { _ in true },
                     field: (String, BrowserTypingFieldLabels) -> Bool = { _, _ in true },
                     anyFocus: Bool = false) -> BrowserTypingJoinResult {
        let proven = previous
        let departed = departedPage
        departedPage = nil
        heldBox = nil; boxRefusal = nil; heldEpisode = nil; episodeTitle = nil
        if anyFocus, previous == nil { previous = departed }
        let before = previous
        // QF-17: the bracketed design takes one batched read per call (`bracketedAttempt`); the synchronous design
        // (the default) the double read below.
        let result = design == .bracketed
            ? bracketedAttempt(environment: e, appleEvents: ae, accessibility: ax, blockList: blockList, alwaysBlocked: alwaysBlocked,
                               sites: sites, field: field, anyFocus: anyFocus)
            : attempt(environment: e, appleEvents: ae, accessibility: ax, blockList: blockList, alwaysBlocked: alwaysBlocked,
                      sites: sites, field: field, anyFocus: anyFocus)
        if let denial = result.denial {
            invalidate()
            if !anyFocus, denial == .field { departedPage = before }
            if anyFocus, !Self.forgetsPageWhenClickDenied.contains(denial) { previous = proven }
            // Codex 07:10 (field hold): a full join that refused a text box it couldn't prove keeps that box.
            if !anyFocus, denial == .field, let b = boxRefusal { heldBox = b }
            // fix/chrome-x: a page episode refused for a reason that stays true until something changes: remember what was
            // in focus (Accessibility only, no Apple Event), so the next keys are held instead of joining again. Only
            // when this join had already read the window title (a refusal before any page read reads nothing more).
            if !anyFocus, BrowserTypingBurst.episodeDenials.contains(denial), let seen = episodeTitle, let pid = e.target()?.pid,
               focused(ax, pid), let window = ax.focusedWindow(), ax.equal(window, seen.window), let focus = ax.focusedElement() {
                heldEpisode = (pid, window, focus, seen.titleHash)
            }
        }
        boxRefusal = nil; episodeTitle = nil
        return result
    }
    /// A click join refused for one of these forgets the page (privacy: an
    /// Incognito or Guest window, a blocked site or one whose switch is off,
    /// typing off, a secure or unreadable focus). Any other refusal keeps the
    /// page the last allowed join proved (`join`).
    static var forgetsPageWhenClickDenied: Set<BrowserTypingDenial> { [.notNormal, .blockedSite, .disabled, .sensitiveField, .field] }

    /// One join. An allowed result has updated `previous` (and `anchor`);
    /// `join` handles a denied one.
    private func attempt(environment e: ChromeJoinEnvironment, appleEvents ae: (ChromeJoinRequest) -> ChromeJoinReply?,
                         accessibility ax: ChromeAXAccess<Node>, blockList: BrowserTypingBlockList, alwaysBlocked: [String],
                         sites: (String) -> Bool, field: (String, BrowserTypingFieldLabels) -> Bool,
                         anyFocus: Bool) -> BrowserTypingJoinResult {
        let began = e.now()
        // Review G51: a slow Chrome stops the join at its budget, not after
        // every Accessibility read (each may wait up to its own timeout).
        let deadline = began &+ BrowserTypingTiming.joinBudgetNanoseconds
        // Once per join, before any Apple Event: consent, the signed target
        // (one process, new enough), and Automation already granted.
        guard e.enabled() else { return .denied(.disabled) }
        guard let target = e.target(), ChromeTargetPolicy.accepts(target) else { return .denied(.untrustedTarget) }
        guard e.automationPermitted(target.pid) else { return .denied(.noPermission) }
        let first: Read
        switch read(e, ae, ax, target, confirming: false, field: field, anyFocus: anyFocus, deadline: deadline) { case .failure(let d): return .denied(d); case .success(let r): first = r }
        // Blocks win before the confirming read: a blocked page gets no second look.
        guard case .allowed(let origin) = BrowserTypingSites.evaluate(first.url, blockList: blockList, alwaysBlocked: alwaysBlocked),
              BrowserTypingSites.evaluate(first.axURL, blockList: blockList, alwaysBlocked: alwaysBlocked) == .allowed(origin: origin),
              sites(first.url), sites(first.axURL)
        else { return .denied(.blockedSite) }
        let second: Read
        switch read(e, ae, ax, target, confirming: true, field: field, anyFocus: anyFocus, deadline: deadline) { case .failure(let d): return .denied(d); case .success(let r): second = r }
        guard unchanged(first, second, ax) else { return .denied(.changed) }
        let ended = e.now()
        guard ended >= began, ended - began <= BrowserTypingTiming.joinBudgetNanoseconds else { return .denied(.timeout) }

        // UUIDs name exact retained AX objects plus the page, never guessed IDs.
        var hasher = Hasher(); hasher.combine(first.windowID); hasher.combine(first.tabID); hasher.combine(first.url.split(separator: "#", maxSplits: 1).first.map(String.init) ?? "")
        let document = hasher.finalize()
        let same = previous.map { $0.target == target.launchIdentity && $0.windowID == first.windowID && $0.tabID == first.tabID
            && $0.document == document && ax.equal($0.window, first.window) && ax.equal($0.webArea, first.webArea) } ?? false
        let documentID = same ? previous!.documentID : UUID().uuidString
        let focusID = same && ax.equal(previous!.focus, first.focus) ? previous!.focusID : UUID().uuidString
        previous = (target.launchIdentity, first.windowID, first.tabID, document, first.window, first.webArea, first.focus, documentID, focusID)
        var proof = BrowserTypingJoinProof(origin: origin, windowID: first.windowID, tabID: first.tabID, windowList: first.ids,
            documentID: documentID, focusID: focusID, targetIdentity: target.launchIdentity, role: first.role,
            subrole: first.subrole, checkedAt: began)
        proof.sendField = first.sendField; proof.sendPlace = first.sendPlace
        proof.pageTitle = WebTypingTitle.clean(first.pageName, url: first.url, origin: origin)
        proof.composeRoute = first.composeRoute; proof.replyLabels = first.replyLabels
        proof.titleObservedAt = first.titleObservedAt
        if !anyFocus {
            trail = BrowserFieldTrail(targetIdentity: target.launchIdentity, windowID: first.windowID, tabID: first.tabID, documentID: documentID,
                                      focusID: focusID, focus: first.focus, chain: first.chain, webArea: first.webArea, checkedAt: began)
        }
        // A click join proves a page, not a field: the next key takes a full join.
        anchor = anyFocus || first.chain.count < 2 ? nil
            : Anchor(pid: target.pid, ids: first.ids, windows: first.windows, window: first.window, focus: first.focus, parent: first.chain[1],
                     webArea: first.webArea, url: first.url, axURL: first.axURL, proof: proof)
        return .allowed(proof)
    }

    /// The light per-key check (review G51: a full join for every key kept
    /// the main thread busy for most of the key's lag budget). It never
    /// denies: nil means "no light proof", and the caller takes the full
    /// join, which decides. It vouches for a key only when a full join allowed
    /// this text field less than `proofTTL` ago and, in this order:
    /// consent is still on; Chrome is the same launch, frontmost and focused,
    /// with no secure input; the window list is the same and every window
    /// still answers "normal" (before anything else about a window or its
    /// page is read); Accessibility shows the same windows; the focused
    /// window, the focused field and its parent are the same objects, with
    /// the same text role and a subrole that isn't secure; the page's address
    /// is the same and still allowed (block lists and the person's choices);
    /// the field's labels, read again, are neither sensitive nor refused;
    /// then the window list, focus and secure input are read again and
    /// consent is asked again; all within `lightBudget`. Its proof carries
    /// the full join's IDs and `light`, so it can admit a key of that burst
    /// but never start one, save, settle or prove a click.
    public func light(environment e: ChromeJoinEnvironment, appleEvents ae: (ChromeJoinRequest) -> ChromeJoinReply?,
                      accessibility ax: ChromeAXAccess<Node>, blockList: BrowserTypingBlockList,
                      alwaysBlocked: [String] = PrivacySettings.sensitiveDomains,
                      sites: (String) -> Bool = { _ in true },
                      field: (String, BrowserTypingFieldLabels) -> Bool = { _, _ in true }) -> BrowserTypingJoinResult? {
        // QF-17 M3: in the bracketed design the light check never admits and never bridges a chain.
        guard design == .synchronous, let a = anchor else { return nil }
        let began = e.now()
        guard began >= a.proof.checkedAt, began - a.proof.checkedAt <= BrowserTypingTiming.proofTTLNanoseconds else { anchor = nil; return nil }
        guard e.enabled(), e.launchIdentity(a.pid) == a.proof.targetIdentity, focused(ax, a.pid) else { return nil }
        guard ae(.windowIDs) == .ids(a.ids) else { return nil }
        // fix/chrome-root: every window's mode in one event (QF-17's batched read), as many answers as windows.
        guard case .texts(let modes)? = ae(.modes), modes.count == a.ids.count, modes.allSatisfy({ $0 == "normal" }) else { return nil }
        guard let all = ax.windows(), all.count == a.windows.count, zip(all, a.windows).allSatisfy({ ax.equal($0, $1) }),
              let window = ax.focusedWindow(), ax.equal(window, a.window),
              let focus = ax.focusedElement(), ax.equal(focus, a.focus), ax.owner(focus) == a.pid,
              ax.role(focus) == a.proof.role, ax.textBox(focus, role: a.proof.role), let subrole = ax.subrole(focus), subrole == a.proof.subrole,
              !subrole.lowercased().contains("secure"), let parent = ax.parent(focus), ax.equal(parent, a.parent) else { return nil }
        guard let axURL = ax.url(a.webArea), axURL == a.axURL,
              case .allowed(let origin) = BrowserTypingSites.evaluate(a.url, blockList: blockList, alwaysBlocked: alwaysBlocked),
              origin == a.proof.origin, BrowserTypingSites.evaluate(axURL, blockList: blockList, alwaysBlocked: alwaysBlocked) == .allowed(origin: origin),
              sites(a.url), sites(axURL) else { return nil }
        guard let labels = ax.fieldLabels(focus), !BrowserTypingFieldRules.denies(labels), field(a.url, labels) else { return nil }
        guard !BrowserTypingFieldRules.unlabelled(role: a.proof.role, subrole: subrole, labels: labels) else { return nil }
        guard ae(.windowIDs) == .ids(a.ids), focused(ax, a.pid), e.enabled() else { return nil }
        let ended = e.now()
        guard ended >= began, ended - began <= BrowserTypingTiming.lightBudgetNanoseconds else { return nil }
        let p = a.proof
        var light = BrowserTypingJoinProof(origin: p.origin, windowID: p.windowID, tabID: p.tabID, windowList: p.windowList,
                                           documentID: p.documentID, focusID: p.focusID, targetIdentity: p.targetIdentity,
                                           role: p.role, subrole: p.subrole, checkedAt: began, light: true)
        // The field's metadata the full join read (fix/typing-e2e: a unit a light key ends keeps its place and send facts).
        light.sendField = p.sendField; light.sendPlace = p.sendPlace; light.pageTitle = p.pageTitle; light.composeRoute = p.composeRoute; light.replyLabels = p.replyLabels; light.titleObservedAt = p.titleObservedAt; light.axURLObservedAt = p.axURLObservedAt; light.leanRead = p.leanRead
        return .allowed(light)
    }

    func focused(_ ax: ChromeAXAccess<Node>, _ pid: Int32) -> Bool {
        ax.frontmostPID() == pid && ax.systemFocusedPID() == pid && !ax.secureInput()
    }

    /// One full read. Order matters and is asserted by call-recording tests
    /// and scripts/check_browser_boundary.py.
    private func read(_ e: ChromeJoinEnvironment, _ ae: (ChromeJoinRequest) -> ChromeJoinReply?, _ ax: ChromeAXAccess<Node>,
                      _ target: ChromeTargetFacts, confirming: Bool,
                      field: (String, BrowserTypingFieldLabels) -> Bool, anyFocus: Bool, deadline: UInt64) -> Result<Read, BrowserTypingDenial> {
        func late() -> Bool { e.now() > deadline }
        // claude/typing-1004: which window or frame step refused, in the always-on tally (`WebTypingRefusals.step`):
        // a full join's first read only, never a click join's or the confirming read's, never a privacy fact.
        let tally = !confirming && !anyFocus
        func step(_ name: StaticString) { if tally { WebTypingRefusals.shared.step(name) } }
        // 0. Still enabled, Chrome frontmost and focused, no secure input.
        guard e.enabled() else { return .failure(.disabled) }
        guard focused(ax, target.pid) else { return .failure(.notFocused) }
        // 1. Window identities only.
        guard case .ids(let ids)? = ae(.windowIDs), !ids.isEmpty, ids.count <= BrowserTypingTiming.maxWindows,
              Set(ids).count == ids.count, ids.allSatisfy(ChromeAppleEvents.validID) else { return .failure(.windowList) }
        // 2. Strict mode: every window answers exactly "normal" before
        //    anything else about any window (or its page) is read.
        //    fix/chrome-root: one event for every window (QF-17's batched read,
        //    `mode of every window`), as many answers as IDs; was one event per
        //    window, which no join budget could pay for on a real Mac.
        guard case .texts(let modes)? = ae(.modes), modes.count == ids.count, modes.allSatisfy({ $0 == "normal" })
        else { return .failure(.notNormal) }
        // 3. Accessibility geometry of the focused window.
        guard let window = ax.focusedWindow(), ax.owner(window) == target.pid, ax.role(window) == "AXWindow",
              ax.subrole(window) == "AXStandardWindow", ax.minimized(window) == false,
              let frame = ax.frame(window), frame.valid else { step("window.focused"); return .failure(.window) }
        // 4. Every window Accessibility shows for Chrome, geometry only. The
        //    focused window must be one of them, and no other standard window
        //    (minimized or not) may share its frame: a same-frame twin is
        //    indistinguishable without reading it.
        guard let all = ax.windows(), all.count <= BrowserTypingTiming.maxWindows,
              all.contains(where: { ax.equal($0, window) }) else { return .failure(.unlistedWindow) }
        var axFrames: [ChromeBounds] = []
        for w in all {
            guard let sub = ax.subrole(w) else { return .failure(.unlistedWindow) }
            guard sub == "AXStandardWindow" else { continue }
            guard let f = ax.frame(w), f.valid else { return .failure(.unlistedWindow) }
            axFrames.append(f)
        }
        guard axFrames.count <= ids.count else { return .failure(.unlistedWindow) }
        guard axFrames.filter({ $0.matches(frame) }).count == 1 else { return .failure(.ambiguousWindow) }
        guard !late() else { return .failure(.timeout) }
        // 5. Apple Events bounds of every (normal) window, one event
        //    (fix/chrome-root: QF-17's batched read; was one event per window).
        guard case .boundsList(let bounds)? = ae(.allBounds), bounds.count == ids.count, bounds.allSatisfy(\.valid)
        else { step("window.bounds"); return .failure(.window) }
        // 6. The window list again: nothing opened or closed meanwhile, and
        //    (M6) the bounds pair with the IDs by index only because the list
        //    is identical after them.
        guard ae(.windowIDs) == .ids(ids) else { return .failure(.changed) }
        // 7. Every Accessibility window is a listed window, one to one on
        //    bounds, before any title, tab, URL or page is read.
        guard ChromeWindowMatching.coversAll(axFrames, bounds) else { return .failure(.unlistedWindow) }
        // 8. Names only of the listed windows with the focused window's bounds.
        let candidates = ids.indices.filter { bounds[$0].matches(frame) }
        guard !candidates.isEmpty else { step("window.noBounds"); return .failure(.window) }
        var names: [String] = []
        for i in candidates {
            guard case .text(let n)? = ae(.name(ids[i])), n.utf8.count <= 4096 else { step("window.name"); return .failure(.window) }
            names.append(n)
        }
        // 9. AE <-> AX window match: bounds and name, exactly one window.
        let titleObservedAt = e.now()
        guard let title = ax.title(window) else { step("window.axTitle"); return .failure(.window) }
        episodeTitle = (window, title.hashValue)
        let matches = candidates.indices.filter { ChromeWindowMatching.titleMatches(axTitle: title, aeName: names[$0]) }
        // Diagnostics (metadata only): the shape of the match, never a title.
        if !confirming { CaptureDiagnostics.shared.hold("join.title", ChromeWindowMatching.shape(axTitle: title, names: candidates.indices.map { names[$0] })) }
        // claude/typing-1004 (owner laptop 10/04, public 0.1.4: every website join refused `window` on an X reply, as on
        // 9/30 (QF-10) and 10/03 (fix/chrome-x), each time a new shape of Chrome's accessible window title). Bounds
        // already bind the focused window to ONE listed window when exactly one listed window has its frame: step 4
        // found no same-frame twin among Accessibility's windows, step 7 paired every one of them with a listed window
        // on bounds, and step 2 found every listed window normal. The title is then a tiebreaker only, as in the
        // bracketed design's lean read; with several same-bounds candidates (another Space) it still decides, exactly.
        // The page itself is still proven by step 12 (the tab's address equals the web area's, same origin, path and
        // query), so a tab switched between the reads is still refused. A window let through on its bounds saves no page
        // title (site only, as Q-4's too-early title): the name it couldn't match may lag the page.
        let pick: Int
        if matches.count == 1 { pick = matches[0] }
        else if matches.count > 1 { return .failure(.ambiguousWindow) }
        else if candidates.count == 1 { pick = 0; step("window.titleUnmatched") }
        else { step("window.title"); return .failure(.window) }
        let windowID = ids[candidates[pick]]
        // 10. The window's active tab and its URL.
        guard case .text(let tabID)? = ae(.activeTabID(windowID)), ChromeAppleEvents.validID(tabID),
              case .text(let url)? = ae(.tabURL(windowID, tabID)), url.utf8.count <= 8192 else { return .failure(.url) }
        // 11. The focused field and its ancestry: a text role, not secure,
        //     exactly one AXWebArea above it (no iframes), reaching the window.
        //     The click join (`anyFocus`) takes any focused element of the page
        //     (a button may have no subrole: ""), still never a secure one, and
        //     never one whose subrole can't be read (review G12: a click join
        //     now also proves that focus left a field for something not secure).
        guard !late() else { return .failure(.timeout) }
        guard let focus = ax.focusedElement(), ax.owner(focus) == target.pid, let role = ax.role(focus),
              anyFocus || ax.textBox(focus, role: role), !role.lowercased().contains("secure"), let subrole = ax.subrole(focus),
              !subrole.lowercased().contains("secure") else { noteSecureFocus(ax); return .failure(.field) }
        // QF-11: a field that was a password field (secure) when a join last saw it, now shown as text.
        guard !secureFocus.contains(where: { ax.equal($0, focus) }) else { return .failure(.sensitiveField) }
        var cursor: Node? = focus, chain: [Node] = [], webAreas: [Node] = [], reached = false
        for _ in 0..<BrowserTypingTiming.maxAncestors {
            guard !late() else { return .failure(.timeout) }
            guard let node = cursor, ax.owner(node) == target.pid, let r = ax.role(node), !r.lowercased().contains("secure"),
                  !chain.contains(where: { ax.equal($0, node) }) else { step("frame.chain"); return .failure(.frame) }
            chain.append(node)
            if r == "AXWebArea" { webAreas.append(node) }
            if ax.equal(node, window) { reached = true; break }
            cursor = ax.parent(node)
        }
        // claude/typing-1004: no web area above the field is Chrome's own UI (the address bar: its searches are saved
        // from the results page's address, `WebTypingRoute.recordSearch`); several are a frame inside the page.
        guard reached, webAreas.count == 1 else {
            step(!reached ? "frame.chain" : webAreas.isEmpty ? "frame.chromeUI" : "frame.nested"); return .failure(.frame)
        }
        // 12. Same page on both sides: http(s), same origin, same path and query.
        guard let axURL = ax.url(webAreas[0]), let o1 = BrowserTypingSites.origin(url), let o2 = BrowserTypingSites.origin(axURL),
              o1 == o2, BrowserTypingSites.sameDocument(url, axURL) else { return .failure(.url) }
        // 13. The field's labels, id and classes: card, code, PIN, password,
        //     terminal. Deny-only; read last, never kept. The click join reads
        //     none: nothing typed is attributed to what it finds focused.
        guard !late() else { return .failure(.timeout) }
        var sendField = "", sendPlace = "", replyLabels: [String] = []
        if !anyFocus {
            guard let labels = ax.fieldLabels(focus) else { return .failure(.field) }
            guard !BrowserTypingFieldRules.denies(labels) else { return .failure(.sensitiveField) }
            // QF-11, QF-3: a field of a form with a password field, or next to a show-password control.
            //      Scanned in both reads (privacy review M7: a password field or toggle added between them denies),
            //      for every kind of box (a one-line box, a text area, a contenteditable box, a search field); a kind that
            //      changes between the reads is `changed` (step 14). A scan that can't finish denies.
            let scanned = BrowserFormScan.scan(chain: chain, ax: ax, late: late)
            if !confirming { CaptureDiagnostics.shared.hold("join.formScan", scanned) }
            switch scanned {
            case .clear: break
            case .password, .reveal: return .failure(.sensitiveField)
            // Review C2: one class for "can't prove": `field`. Keys in this box are refused; text proven earlier in
            // another field can still be saved as it leaves (the box is not evidence that text was secret).
            case .exhausted, .unreadable: boxRefusal = (target.pid, window, focus); return .failure(.field)
            case .late: return .failure(.timeout)
            }
            // QF-4 (option a, Codex 06:10): an unlabelled box of any kind can't be proven not to be a card number, a
            // one-time code or a password shown as text: `field` (review C2's class for "can't prove"), after the scan
            // (a password neighbour is the stronger `sensitiveField`).
            guard !BrowserTypingFieldRules.unlabelled(role: role, subrole: subrole, labels: labels) else {
                boxRefusal = (target.pid, window, focus); return .failure(.field)
            }
            //     A message composer on a site outside the categories follows
            //     Messages and email; off, it is a site whose switch is off.
            guard field(url, labels) else { return .failure(.blockedSite) }
            // summaries/v3: the field class and a chat composer's place, from the same transient labels.
            let search = SendRules.surface(bundle: "", host: BrowserTypingSites.host(of: url)) == "search"
            sendField = SendRules.fieldClass(role: role, labels: labels.texts, composer: BrowserTypingComposerRules.composer(labels), search: search)
            sendPlace = SendRules.composerPlace(labels: labels.texts, host: BrowserTypingSites.host(of: url)) ?? ""
            replyLabels = BrowserComposeRoute.replyMarkers(labels.texts)
        }
        // 14. Confirming read only: the window lists, every mode, focus and
        //     the target again, after all page content.
        if confirming {
            guard ae(.windowIDs) == .ids(ids) else { return .failure(.changed) }
            guard case .texts(let again)? = ae(.modes), again.count == ids.count, again.allSatisfy({ $0 == "normal" })
            else { return .failure(.notNormal) }
            guard let again = ax.windows(), again.count == all.count,
                  zip(again, all).allSatisfy({ ax.equal($0, $1) }) else { return .failure(.changed) }
            guard focused(ax, target.pid) else { return .failure(.notFocused) }
            guard e.launchIdentity(target.pid) == target.launchIdentity else { return .failure(.changed) }
        }
        return .success(Read(ids: ids, axFrames: axFrames, bounds: bounds, candidates: candidates, names: names, windowID: windowID,
                             tabID: tabID, url: url, axURL: axURL, frame: frame, titleObservedAt: titleObservedAt, title: title, pageName: matches.isEmpty ? "" : names[pick],
                             window: window, focus: focus,
                             webArea: webAreas[0], chain: chain, role: role, subrole: subrole, windows: all,
                             sendField: sendField, sendPlace: sendPlace, composeRoute: BrowserComposeRoute.path(url: url), replyLabels: replyLabels))
    }

    private func unchanged(_ a: Read, _ b: Read, _ ax: ChromeAXAccess<Node>) -> Bool {
        a.ids == b.ids && a.axFrames == b.axFrames && a.bounds == b.bounds && a.candidates == b.candidates && a.names == b.names
            && a.windowID == b.windowID && a.tabID == b.tabID && a.url == b.url && a.axURL == b.axURL && a.frame == b.frame
            && a.title == b.title && a.role == b.role && a.subrole == b.subrole && ax.equal(a.window, b.window)
            && ax.equal(a.focus, b.focus) && ax.equal(a.webArea, b.webArea) && a.chain.count == b.chain.count
            && zip(a.chain, b.chain).allSatisfy { ax.equal($0, $1) }
    }
}

// MARK: - Website sites: category table and "Other websites"

extension BrowserTypingSites {
    /// Chrome page history's common search, email and chat hosts
    /// (`BrowserSites.siteOnlyHosts`), split for typing: search engines and AI
    /// chat are Search & AI; every other one (email, and chat with people) is
    /// Messages & email. The most specific matching entry decides
    /// (mail.yandex.com is email although yandex.com is search).
    public static let searchAndAIHosts: Set<String> = ["bing.com", "duckduckgo.com", "search.yahoo.com", "search.brave.com", "ecosia.org",
        "startpage.com", "kagi.com", "yandex.com", "yandex.ru", "baidu.com", "search.aol.com", "chatgpt.com", "chat.openai.com", "claude.ai",
        "gemini.google.com", "copilot.microsoft.com", "perplexity.ai", "poe.com", "character.ai", "chat.mistral.ai", "meta.ai", "grok.com",
        "chat.deepseek.com", "you.com", "aistudio.google.com", "chat.qwen.ai", "pi.ai", "copilot.cloud.microsoft"]
    /// Social sites whose chat opens over any page while the address stays on
    /// the feed (LinkedIn's messaging pop-up on linkedin.com/feed, Messenger
    /// chat boxes on facebook.com, the message drawer on x.com/home). Their
    /// message paths alone (`BrowserSites.siteOnlyPaths`) can't tell a chat
    /// box from the feed, so for typing every page on them counts as Messages
    /// & email: a chat typed there follows the Messages and email checkbox.
    /// Every one is also in `messagingHosts`, which `rule` reads (the docs
    /// name these; WebTypingChecks pins that each is a messaging site).
    public static let socialChatHosts: Set<String> = ["facebook.com", "linkedin.com", "x.com", "twitter.com", "instagram.com", "reddit.com"]
    /// AI chat pages on otherwise ordinary sites (the rest of
    /// `BrowserSites.siteOnlyPaths` are message pages).
    public static let searchAndAIPaths: [(host: String, path: String)] = [("huggingface.co", "/chat"), ("m365.cloud.microsoft", "/chat")]

    /// Sites where any page can hold a message composer (a chat drawer, a
    /// messaging overlay, a direct-message box or a call's chat), so the whole
    /// site is Messages and email, whatever the page (review F1: Messenger
    /// pops up on facebook.com/, LinkedIn's messaging overlay on /feed/, X's
    /// message drawer on /home, texts on voice.google.com). Suffix match, like
    /// every site rule. Not complete: pages elsewhere are caught by their
    /// composer's labels (`BrowserTypingComposerRules`), and the owner can
    /// block any site.
    public static let messagingHosts = [
        // Social sites with messaging on every page.
        "facebook.com", "messenger.com", "instagram.com", "threads.net", "threads.com", "linkedin.com", "x.com", "twitter.com",
        "reddit.com", "tiktok.com", "pinterest.com", "tumblr.com", "bsky.app", "vk.com", "snapchat.com",
        // Messaging, team chat and calls on the web.
        "whatsapp.com", "telegram.org", "discord.com", "discordapp.com", "slack.com", "teams.microsoft.com", "teams.live.com",
        "teams.cloud.microsoft", "chat.google.com", "messages.google.com", "voice.google.com", "meet.google.com", "hangouts.google.com",
        "skype.com", "wechat.com", "wx.qq.com", "wx2.qq.com", "line.me", "groupme.com", "app.element.io", "app.zoom.us",
        "twitch.tv", "kick.com",
        // Shared inboxes and support chat.
        "app.intercom.com", "app.frontapp.com", "app.crisp.chat",
        // Email and chat that page history's list doesn't name, or files under
        // another category (yandex.ru is Search and AI; its messenger isn't).
        "exmail.qq.com", "outlook.office365.us", "app.shortwave.com", "groups.google.com", "app.ringcentral.com",
        "messenger.yandex.ru", "messenger.yandex.com"]
    /// A first host label that names a webmail host ("mail.notion.so",
    /// "mail.zoho.in", "webmail.example.org", "owa.example.com"): Messages and
    /// email, whatever the site's table category.
    public static let mailHostLabels: Set<String> = ["mail", "webmail", "email", "owa"]
    /// A first path segment that names a webmail app on any host
    /// ("/owa/", "/webmail/", "/roundcube/", "/SOGo/").
    public static let mailPathSegments: Set<String> = ["owa", "webmail", "roundcube", "sogo"]
    /// Message pages on hosts whose own category is something else
    /// (Yandex Messenger on yandex.ru, a Search and AI host).
    public static let messagingPaths: [(host: String, path: String)] = [("yandex.ru", "/chat"), ("yandex.com", "/chat")]
    /// Whether every page of this host counts as Messages and email.
    public static func messagingSite(host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if let first = h.split(separator: ".").first, h.contains("."), mailHostLabels.contains(String(first)) { return true }
        return messagingHosts.contains { matches(host: h, domain: $0) }
    }
    /// Whether this page counts as Messages and email by its address: a
    /// messaging site, a webmail path, or a message page on another site.
    static func messagingPage(host: String, path: String?) -> Bool {
        if messagingSite(host: host) { return true }
        guard let path else { return false }
        let lower = path.lowercased()
        if let first = lower.split(separator: "/").first, mailPathSegments.contains(String(first)) { return true }
        return messagingPaths.contains { matches(host: host, domain: $0.host) && (lower == $0.path || lower.hasPrefix($0.path + "/")) }
    }

    /// The category of a common search, email or chat host, or nil.
    public static func siteOnlyCategory(host: String) -> TypingCategory? {
        let h = host.lowercased()
        if h.range(of: "^(www\\.)?google(\\.[a-z]{2,3}){1,2}$", options: .regularExpression) != nil { return .searchAndAI }
        guard let entry = BrowserSites.siteOnlyHosts.filter({ matches(host: h, domain: $0) }).max(by: { $0.count < $1.count }) else { return nil }
        return searchAndAIHosts.contains(entry) ? .searchAndAI : .messagesAndEmail
    }
    /// What a page counts as for typing. `path` nil (or "/") and `search`
    /// false is the host-only rule, which the gate and the store use; the
    /// join also asks the full address (message and AI chat pages on
    /// ordinary sites, search result pages). A never page stays never; a
    /// messaging page (`messagingPage`) is Messages and email, before the
    /// table's categories and before a search address (both rules, so the
    /// host rule the gate and the store read agrees with the join). It never
    /// allows more than `tableRule` did: `permits` needs both (review F1
    /// follow-up: Messages and email on doesn't open a feed page that Other
    /// websites off closes).
    public static func rule(host rawHost: String, path: String? = nil, search: Bool = false) -> TypingSiteRule {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let table = tableRule(host: host, path: path, search: search)
        if table == .never { return .never }
        return messagingPage(host: host, path: path) ? .category(.messagesAndEmail) : table
    }
    /// The rule before messaging pages: the table, page history's search,
    /// email and chat hosts, AI chat and message paths, and search addresses.
    public static func tableRule(host rawHost: String, path: String? = nil, search: Bool = false) -> TypingSiteRule {
        let host = rawHost.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let table = TypingCategories.site(host: host, path: path ?? "/")
        guard table == .other else { return table }
        if let category = siteOnlyCategory(host: host) { return .category(category) }
        if let path {
            let lower = path.lowercased()
            if searchAndAIPaths.contains(where: { matches(host: host, domain: $0.host) && (lower == $0.path || lower.hasPrefix($0.path + "/")) }) {
                return .category(.searchAndAI)
            }
            if BrowserSites.messagePath(host: host, path: path) { return .category(.messagesAndEmail) }
        }
        return search ? .category(.searchAndAI) : .other
    }
    /// The rule for a full address (read, decided on and dropped).
    /// `search` false leaves out the search reading of the query (the
    /// composer rule asks what the page is apart from a `?q=`, `?p=` or `?s=`).
    public static func rule(url: String, search: Bool = true) -> TypingSiteRule {
        guard let p = BrowserSites.parts(url) else { return .never }
        return rule(host: p.host, path: p.components.path.isEmpty ? "/" : p.components.path, search: search && BrowserSites.searchQuery(p.components))
    }
    public static func tableRule(url: String) -> TypingSiteRule {
        guard let p = BrowserSites.parts(url) else { return .never }
        return tableRule(host: p.host, path: p.components.path.isEmpty ? "/" : p.components.path, search: BrowserSites.searchQuery(p.components))
    }
    /// The pages whose message composers follow Messages and email as well.
    static func composerRuleApplies(_ rule: TypingSiteRule) -> Bool { rule == .other || rule == .category(.writing) }
    static func allows(_ rule: TypingSiteRule, _ choices: TypedCategoryChoices) -> Bool {
        switch rule {
        case .never: return false
        case .category(let c): return choices.isOn(c)
        case .other: return choices.otherWebsites
        }
    }
    /// Whether typing on this address is allowed: the build allows website
    /// typing (`expanded`), no block list matches (Chrome page history's
    /// defaults, the typing-only blocks, the pinned sensitive sites and the
    /// owner's own list: `alwaysBlocked`), and both the full-address rule and
    /// the host rule are switched on. A messaging page needs Messages and
    /// email on top of what its table rule needs (Other websites for
    /// facebook.com/, Search and AI for x.com/search?q=), never instead of
    /// it: the messaging rule only ever refuses more.
    public static func permits(url: String, choices: TypedCategoryChoices, blockList: BrowserTypingBlockList = BrowserTypingBlockList(),
                               alwaysBlocked: [String], expanded: Bool = TypingRelease.open) -> Bool {
        guard expanded, case .allowed(let origin) = evaluate(url, blockList: blockList, alwaysBlocked: alwaysBlocked),
              let host = host(of: origin) else { return false }
        return [rule(url: url), rule(host: host), tableRule(url: url), tableRule(host: host)].allSatisfy { allows($0, choices) }
    }
}

/// The person's website choices and block lists, read by the join (full
/// address), the website gate (host) and the store (host). One object, so a
/// change reaches all three at once.
public final class BrowserTypingSiteRules {
    public var choices: TypedCategoryChoices
    /// The pinned sensitive sites plus the owner's own "Sites not recorded"
    /// (`PrivacySettings.blockedDomains`, which "Don't record this site" adds to).
    public var alwaysBlocked: [String]
    public var blockList: BrowserTypingBlockList
    public let expanded: Bool
    public init(choices: TypedCategoryChoices = TypedCategoryChoices(), alwaysBlocked: [String] = PrivacySettings.sensitiveDomains,
                blockList: BrowserTypingBlockList = BrowserTypingBlockList(), expanded: Bool = TypingRelease.open) {
        self.choices = choices; self.alwaysBlocked = alwaysBlocked; self.blockList = blockList; self.expanded = expanded
    }
    /// From the saved settings: the typing policy's choices and the owner's site list.
    public convenience init(policy: TypedTextPolicy, settings: PrivacySettings, expanded: Bool = TypingRelease.open) {
        self.init(choices: policy.categories, alwaysBlocked: PrivacySettings.sensitiveDomains + settings.blockedDomains, expanded: expanded)
    }
    public func permits(url: String) -> Bool {
        BrowserTypingSites.permits(url: url, choices: choices, blockList: blockList, alwaysBlocked: alwaysBlocked, expanded: expanded)
    }
    public func permits(host: String) -> Bool { permits(url: "https://" + host) }
    /// The focused field (the join only; its labels are read, decided on and
    /// dropped): on a page outside the categories ("Other websites") or a
    /// Writing page, a message composer (`BrowserTypingComposerRules`)
    /// follows Messages and email too. What the page is comes from its
    /// address without the search reading, so `?q=`, `?p=`, `?s=` or `?text=`
    /// never turns the rule off. Search and AI pages keep their own boxes
    /// (an AI prompt reads "Message ChatGPT"); messaging pages already need
    /// Messages and email.
    public func permits(url: String, field: BrowserTypingFieldLabels) -> Bool {
        guard permits(url: url) else { return false }
        guard BrowserTypingSites.composerRuleApplies(BrowserTypingSites.rule(url: url, search: false)),
              BrowserTypingComposerRules.composer(field) else { return true }
        return choices.messagesAndEmail
    }
}

// MARK: - Website typing: the burst rules on TypingSession

/// Website typing (typesafe SPEC 12.2 item 5). The words are kept, edited,
/// latched, split and classified by the same `TypingSession` native typing
/// uses, with `WebTypingGate` as its gate. This class adds the Chrome join's
/// burst rules around it. Invariants (tested, not optimisations):
/// 1. synchronous design (`ChromeJoinDesign.synchronous`, the default): a
///    key is read only after a fresh allowed join taken after it was
///    typed, the burst rules, the gate and the secret latch allow it; a burst
///    starts with a full join, and later keys of it may be admitted by the
///    light per-key check (`BrowserTypingJoin.light`: the same window list,
///    modes, windows, focused field, page and labels as a full join of less
///    than `proofTTL` ago), which never saves.
///    QF-17 bracketed design (prototype, needs the privacy reviewer's approval
///    of the diff): a key's characters may be held in memory, unproven, in the
///    route's owned buffer (`ChromeHeldKeys`) for at most its bracket, capped at
///    64 keys and 1 s, and only while a read that started before the key is
///    running, no denial quiet period or refusal hold is on, secure input is off,
///    ordinary boundary quiet has ended (or opt-in recovery has a complete read
///    starting strictly after that boundary and ending before the key), and
///    Chrome is frontmost with the key-time focus refs of the last verified
///    read; nothing is written, logged or counted per key before proof. A key
///    is handed to the session only when verified reads bracket it
///    (`ChromeBracketEngine`: every fact equal, observed before and after it,
///    each fact's span within `ChromeBracketTiming.spanNanoseconds`, no boundary
///    inside) (`admitBracketed`); any privacy refusal wipes every held key;
/// 2. any change of window, tab, page, field or window list between keys
///    discards the unfinished text (the next key starts a new burst);
/// 3. synchronous design: a key or Return processed more than
///    `maxKeyLagNanoseconds` after it was typed is refused, and so is any key
///    whose join started before it was typed: the join must describe the
///    moment after the key. Bracketed design: the tap's input-lag bound is
///    unchanged (a key processed more than 150 ms after it was typed is refused
///    at intake), but attribution no longer uses the post-join lag rule: it
///    uses the bracket (a verified read ended before the key, a verified read
///    started after it, per-fact spans within the limit), and a save still
///    needs a read that started after its boundary;
/// 4. a denial (or a late key) starts the quiet period, measured against the
///    time keys were typed, so keys typed while Chrome was in a denied state
///    and processed later are dropped too;
/// 5. a live save needs a fresh allowed full join of the same burst, with
///    the window list it started with; a parked unit is saved only when fresh
///    joins of the same page and window list find focus in the field of the
///    last admitted key, in another text field the full join allowed, or on
///    something that is not a text field and not secure (`resolveParked`);
///    at a click or a chorded Return the live unit is saved first, with a
///    click join of the same page and window list taken after the button
///    went down or the key was typed (`pointerDown`);
/// 6. an Incognito or Guest window, a sensitive field, a blocked site or a
///    site whose switch is off drops everything unsaved (privacy boundary);
/// 7. (battery) a plain key these rules would drop whatever a join said (the
///    quiet period, or the hold after a privacy refusal) takes no join and
///    reads nothing (`dropsUnread`).
public final class BrowserTypingBurst {
    public private(set) var start: BrowserTypingJoinProof?
    /// Start of the latest quiet period.
    public private(set) var quietFrom: UInt64?
    /// Codex QF-1 prototype: off until reviewed. Only bracketed keys can recover a
    /// boundary's quiet period, with a full pre-key read that began after the boundary.
    /// A denial's quiet period and every privacy-refusal hold remain enforced.
    public var recoverBracketedBoundaries = false
    private var quietFromBoundary = false
    public var recoversBracketedQuiet: Bool { bracketed && recoverBracketedBoundaries && quietFromBoundary }
    /// The proof of the last admitted key: the only field a parked unit may be saved from.
    public private(set) var last: BrowserTypingJoinProof?
    /// fix/chrome-x2 (owner, 2026-10-03: an X post and a Google search typed in the page saved nothing): when a send
    /// gesture (Return, Command-Return) parked the burst's text because the page had already reacted to it (the post's
    /// route left, the composer emptied or lost focus, the search page loaded) and its own join could not prove the field
    /// again. The settle (`resolveParked`) may then save the text to the field of its last admitted key when a fresh join
    /// proves the same Chrome, window, tab, site and window list, the address aside (`sameTab`). Cleared by the next
    /// burst, any invalidation, and after `sendSettleNanoseconds`.
    public private(set) var sendParkedAt: UInt64?
    public static let sendSettleNanoseconds: UInt64 = 3_000_000_000
    /// The join refusals a page's own reaction to a send can cause (the composer cleared or closed, focus moved to the
    /// page or a button, the route or title changed mid-read, a slow Chrome). Never a privacy refusal: an Incognito or
    /// Guest window, a sensitive field, a blocked site, typing off, another target, no permission, another app in front, or a
    /// changed window list drop the text as before.
    public static let sendReactions: Set<BrowserTypingDenial> = [.field, .frame, .url, .window, .ambiguousWindow, .changed, .timeout]
    /// Only where Return or Command-Return sends (`SendRules`: a chat, AI, social, search or webmail page). Anywhere else
    /// (a notes page, a form) a refused send gesture drops the text as before (review G12).
    public static let sendSurfaces: Set<String> = ["ai", "aiTool", "chat", "email", "social", "search"]
    private func sendBurst() -> Bool {
        guard session.hasLive, let s = start, let l = last, s.sameBurst(as: l), let host = BrowserTypingSites.host(of: l.origin) else { return false }
        return Self.sendSurfaces.contains(SendRules.surface(bundle: WebTypingGate.bundle, host: host, title: host, field: l.sendField.isEmpty ? "unknown" : l.sendField))
    }
    public let session: TypingSession
    public let sites: BrowserTypingSiteRules
    public init(sites: BrowserTypingSiteRules = BrowserTypingSiteRules(), limits: TypingLimits = TypingLimits()) {
        self.sites = sites
        // No terminal prompt latch: web terminals are blocked sites and fields.
        session = TypingSession(limits: limits, promptLatchApps: { _ in false }, gate: { p, policy, generation, now in
            WebTypingGate.typing(p, policy: policy, generation: generation, now: now, expanded: sites.expanded, site: sites.permits(host:))
        })
        // claude/livefix-1004: a click or caret move inside the same box keeps the post or message one run.
        session.pointerContinuesRun = true
    }
    /// fix/web-textbox (battery): plain keys typed before this are dropped
    /// with no join (`BrowserTypingTiming.refusedHoldNanoseconds`). Set only by
    /// a privacy refusal; cleared by a later disruptive input or invalidation.
    public private(set) var heldUntil: UInt64?
    /// Codex 07:10 (field hold): a key's full join refused the focused text box as `field` (it couldn't be proven)
    /// and nothing disruptive happened since. While the box keeps focus (`key`'s `held`, the join's
    /// `holdsRefusedBox`), plain keys are dropped unread with no join. A pause of `refusedHoldNanoseconds` between
    /// keys, a click, Return, Tab, an arrow, Escape, a shortcut, a key in another app, a window or focus change, an
    /// input-source change (`endHolds`) or any privacy boundary ends it. It only keeps a refusal; it never allows.
    /// Stated costs: a box that gets a label mid-burst (a placeholder drawn late) stays refused until the burst ends;
    /// after a scripted focus move out of the held box (no input), the first quiet period of typing in the next box
    /// (about 400 ms) is dropped (review FH-1).
    public private(set) var fieldHeld = false
    private var fieldHeldKeyAt: UInt64 = 0
    /// fix/chrome-x: when a page-episode hold (`episodeDenials`) began; nil for a `.field` hold (no limit).
    private var episodeHeldSince: UInt64?
    /// fix/chrome-capture (diagnostics): why the last key this burst dropped was dropped. Never the key.
    public private(set) var dropReason: BrowserTypingDrop?
    public var pending: Bool { start != nil }
    public func discard() { start = nil }
    /// A shortcut, Return, Tab, arrow, Escape or click (its typed time): discard and start the quiet period.
    /// A genuinely later event also ends a refusal hold: focus, the page or the window may have changed.
    public func noteDisruptive(at typedAt: UInt64) {
        start = nil
        // An older delayed boundary cannot turn a later denial into recoverable quiet.
        if quietFrom == nil || typedAt > quietFrom! {
            quietFrom = typedAt
            quietFromBoundary = true
            heldUntil = nil
        }
        // The field hold ends at every boundary, as in 9de7d09, whatever the guard above did (review 10:35 Q-1: a
        // delayed boundary that ended it would only send the next key to a full join, which refuses the box again).
        fieldHeld = false
    }
    /// Codex 07:10: an input-source change (or anything else the route sees that isn't a key) ends both holds.
    public func endHolds() { heldUntil = nil; fieldHeld = false }
    /// fix/web-textbox (battery, the owner 2026-09-28: "it is just burning
    /// battery life"): a plain key (typed, deleted or accented) that the burst
    /// rules drop whatever a join would say is dropped without one, so no
    /// Apple Event or Accessibility read is spent on it:
    /// - a key typed in the quiet period (`quietAdmits` refuses it for any proof);
    /// - a key typed within `refusedHoldNanoseconds` of a privacy refusal with
    ///   no disruptive input since (`heldUntil`).
    /// Nothing is read, the burst is discarded and the unfinished text
    /// retracted, as a dropped key does after a join. The quiet period is not
    /// extended, so typing resumes once it ends. Saves (Return, paste, a split,
    /// the settle, a pause, a click) still take their own fresh joins, which
    /// apply every privacy boundary before anything is kept.
    /// QF-17: set by the route in the bracketed design (`admitBracketed`, and `save` without the post-join lag rule).
    public var bracketed = false
    /// QF-17 bracketed design: whether the key typed at `typedAt`, bracketed by verified reads `ra` (ended before
    /// it) and `rb` (started after it), may be added to the burst. Replaces `onTime` + `fresh` for attribution:
    /// `rb` started after the key, and `ra`'s start and the key are both after the quiet period. The proof TTL
    /// only refuses here; it never admits. A light proof never admits.
    /// `bSideSent` (QF-17, perFact only; UNREVIEWED change to this check, 2026-09-30): the earliest send time of the
    /// engine's b-side observations, one per fact. Under perFact the b-side of a key typed inside a read's opening
    /// observation (focusState: the target, Automation and AX focus checks, before any Apple Event) is that same read,
    /// which started before the key, so `rb.checkedAt > typedAt` (its start) refused a key the per-fact rule proved.
    /// `bSideSent > typedAt` says every fact's b-side observation, the opening focusState one included, was sent after
    /// the key: the per-fact form of the same check. nil (wholeRead): the whole-read check, unchanged.
    public func admitBracketed(ra: BrowserTypingJoinProof, rb: BrowserTypingJoinProof, typedAt: UInt64, processedAt: UInt64,
                               bSideSent: UInt64? = nil) -> Bool {
        guard bracketed, !ra.light, !rb.light, ra.checkedAt < typedAt, (bSideSent ?? rb.checkedAt) > typedAt, processedAt >= rb.checkedAt,
              processedAt - rb.checkedAt <= BrowserTypingTiming.proofTTLNanoseconds, ra.sameBurst(as: rb),
              quietAdmits(ra, typedAt: typedAt) else { start = nil; return false }
        if let s = start {
            guard s.sameBurst(as: rb) else { start = nil; return false }
        } else {
            start = rb
        }
        last = rb
        return true
    }
    public func dropsUnread(typedAt: UInt64) -> Bool {
        if let q = quietFrom, !recoversBracketedQuiet, typedAt < q &+ BrowserTypingTiming.quietNanoseconds { return true }
        if let h = heldUntil, typedAt < h { return true }
        return false
    }
    /// A denied or late key (its processing time): discard and start the quiet period.
    /// N-98-1 (review 10:26, hardening): a denial never ends a privacy refusal hold (`heldUntil`); only a user boundary
    /// (`noteDisruptive`), `endHolds` or invalidation does. Was: a strictly later denial (a held key's field-hold drop, a
    /// timeout) cleared it through `noteDisruptive`, and the 400 ms denial quiet replaced the 1 s hold.
    public func noteDenied(at processedAt: UInt64) {
        let hold = heldUntil
        noteDisruptive(at: processedAt)
        quietFromBoundary = false
        heldUntil = hold
    }
    /// Keys typed during the quiet period are dropped, and so is any key
    /// admitted by a join that started before the quiet period ended.
    public func quietAdmits(_ proof: BrowserTypingJoinProof, typedAt: UInt64) -> Bool {
        guard let q = quietFrom else { return true }
        if recoversBracketedQuiet { return typedAt > q && proof.checkedAt > q }
        let end = q &+ BrowserTypingTiming.quietNanoseconds
        return typedAt >= end && proof.checkedAt >= end
    }
    /// Key bytes are never acquired using a read from before an intake boundary.
    /// The engine still separately proves equal complete reads on both sides, no
    /// boundary inside their span, key-time identity, and the 150 ms fact budget.
    public func bracketedIntakeAdmits(typedAt: UInt64, priorReadStartedAt: UInt64, boundaryAt: UInt64?) -> Bool {
        guard bracketed, !dropsUnread(typedAt: typedAt) else { return false }
        guard let boundaryAt else { return true }
        if recoverBracketedBoundaries {
            return typedAt > boundaryAt && priorReadStartedAt > boundaryAt
        }
        return typedAt >= boundaryAt &+ BrowserTypingTiming.quietNanoseconds
    }
    public static func onTime(typedAt: UInt64, processedAt: UInt64) -> Bool {
        processedAt >= typedAt && processedAt - typedAt <= BrowserTypingTiming.maxKeyLagNanoseconds
    }
    /// fix/chrome-root: when processing of a key (or Return) started: its join's start for a proof taken at most
    /// `joinBudgetNanoseconds` before `processedAt`; otherwise (a refusal, or a proof older than a join can take),
    /// `processedAt`, as before.
    public static func processingStart(_ result: BrowserTypingJoinResult, processedAt: UInt64) -> UInt64 {
        guard let p = result.proof, p.checkedAt <= processedAt,
              processedAt - p.checkedAt <= BrowserTypingTiming.joinBudgetNanoseconds else { return processedAt }
        return p.checkedAt
    }
    private func fresh(_ proof: BrowserTypingJoinProof, typedAt: UInt64, processedAt: UInt64) -> Bool {
        proof.checkedAt >= typedAt && processedAt >= proof.checkedAt
            && processedAt - proof.checkedAt <= BrowserTypingTiming.proofTTLNanoseconds
    }
    /// Whether this key may be buffered. Any failure discards the whole burst.
    @discardableResult public func admitKey(_ result: BrowserTypingJoinResult, typedAt: UInt64, processedAt: UInt64) -> Bool {
        // fix/chrome-root: the key's lag is measured to when its join started (`fresh` below still needs the join to
        // start after the key and end within the proof TTL); measured after the join, no key on a real Mac was on time.
        guard Self.onTime(typedAt: typedAt, processedAt: Self.processingStart(result, processedAt: processedAt)), let proof = result.proof else {
            dropReason = result.proof == nil ? .denied : .late
            noteDenied(at: processedAt); return false
        }
        guard fresh(proof, typedAt: typedAt, processedAt: processedAt) else { dropReason = .stale; start = nil; return false }
        guard quietAdmits(proof, typedAt: typedAt) else { dropReason = .quiet; start = nil; return false }
        if let s = start {
            guard s.sameBurst(as: proof) else { dropReason = .otherBurst; start = nil; return false }
        } else {
            // Only a full join starts a burst.
            if proof.light { dropReason = .lightStart }
            guard !proof.light else { return false }
            start = proof
            sendParkedAt = nil
        }
        last = proof
        return true
    }
    /// The origin to store with the burst, or nil (discard). Always consumes
    /// the burst. `typedAt` is the Return's typed time; nil for a timed save,
    /// which is judged at the moment its join started.
    public func save(_ result: BrowserTypingJoinResult, typedAt: UInt64?, processedAt: UInt64) -> String? {
        defer { start = nil }
        // Bracketed design: the boundary was lag-checked at intake; the save's read must still start after it (`fresh`).
        if let t = typedAt, !bracketed, !Self.onTime(typedAt: t, processedAt: Self.processingStart(result, processedAt: processedAt)) { noteDenied(at: processedAt); return nil }
        guard let f = result.proof else { noteDenied(at: processedAt); return nil }
        // A save needs a full join (a light check only admits keys).
        guard !f.light else { return nil }
        let typed = typedAt ?? f.checkedAt
        guard let s = start, fresh(f, typedAt: typed, processedAt: processedAt), quietAdmits(f, typedAt: typed),
              f.windowList == s.windowList, s.sameBurst(as: f) else { return nil }
        return f.origin
    }

    // MARK: Text on the typing session

    /// The typing proof of a join proof. The window list and Chrome's launch
    /// are part of the field's identity (`frameID`), so a window opening or
    /// closing, or a relaunch, is a different field. The place label is the
    /// page's title as Chrome page history saves it (fix/typing-e2e L5), or the
    /// site where page history keeps the site only (search, email and chat).
    public static func focusProof(_ j: BrowserTypingJoinProof, generation: UInt64, policyVersion: UInt64) -> FocusProof {
        var p = FocusProof()
        p.generation = generation; p.policyVersion = policyVersion; p.checkedAt = j.checkedAt
        p.bundle = WebTypingGate.bundle; p.surface = .browser
        p.windowID = j.windowID; p.focusID = j.focusID; p.tabID = j.tabID; p.documentID = j.documentID
        p.frameID = "windows-" + fingerprint(j.targetIdentity + "|" + j.windowList.joined(separator: ","))
        p.role = j.role; p.subrole = j.subrole
        // The join proved these for every window and the focused field.
        p.secureInput = .no; p.privateMode = .no
        p.verified = true; p.fieldStateVerified = true; p.frameAccessible = true; p.navigationStable = true
        p.url = j.origin
        p.place = j.pageTitle.isEmpty ? BrowserTypingSites.host(of: j.origin) ?? "" : j.pageTitle
        p.sendField = j.sendField; p.sendPlace = j.sendPlace
        return p
    }
    public func proof(_ j: BrowserTypingJoinProof, policy: CapturePolicy) -> FocusProof {
        Self.focusProof(j, generation: session.generation, policyVersion: policy.version)
    }
    /// Drops the burst and everything unsaved (a privacy boundary).
    public func invalidate(_ boundary: PrivacyBoundary) {
        start = nil; last = nil; heldUntil = nil; fieldHeld = false; sendParkedAt = nil
        session.invalidate(boundary)
    }
    /// A join that said no. Incognito or Guest, a sensitive or password
    /// field (or focus on something that is not a text field), a blocked
    /// site (or one whose switch is off) and typing turned off drop
    /// everything unsaved; anything else (focus elsewhere, a timeout, a
    /// changed page) drops the unfinished text of this burst.
    public func denied(_ denial: BrowserTypingDenial, at processedAt: UInt64) {
        noteDenied(at: processedAt)
        switch denial {
        case .notNormal: invalidate(.privateMode)
        case .sensitiveField, .field: invalidate(.focus)
        case .blockedSite: invalidate(.navigation)
        case .disabled: invalidate(.policy)
        default: session.retract()
        }
        hold(denial, at: processedAt)
    }
    /// The refusal holds of a denial (`denied`), without dropping anything.
    private func hold(_ denial: BrowserTypingDenial, at processedAt: UInt64) {
        // fix/web-textbox (battery): a refusal that stays true until the
        // person does something else (`dropsUnread`). Not `.field` (a site's
        // own shortcut, like "/" or "n", may move focus into a box with no
        // click) and not a timeout or a changed page (transient).
        if Self.holdingDenials.contains(denial) { heldUntil = processedAt &+ BrowserTypingTiming.refusedHoldNanoseconds }
        // Codex 07:10 (field hold): a refused box holds only while the join's `holdsRefusedBox` finds it focused
        // (focus on a button or the page, the "/" shortcut case above, records no box: every key still joins).
        if denial == .field { fieldHeld = true; fieldHeldKeyAt = processedAt; episodeHeldSince = nil }
        // fix/chrome-x (perf 10-03): a page refusal that stays true until something changes (the X reply's `window`)
        // holds too, at most `episodeHoldNanoseconds`, while the join's `holdsRefusedBox` finds the same window, field
        // and title. It only keeps a refusal; every boundary, a pause, a focus, window or title change ends it.
        if Self.episodeHoldEnabled, Self.episodeDenials.contains(denial) { fieldHeld = true; fieldHeldKeyAt = processedAt; episodeHeldSince = processedAt }
    }
    /// Checks only (the main-thread benchmark's "before"): the app never changes it.
    nonisolated(unsafe) public static var episodeHoldEnabled = true
    public static let episodeDenials: Set<BrowserTypingDenial> = [.window, .unlistedWindow, .ambiguousWindow, .frame, .url, .windowList]
    // (Not `.timeout` or `.changed`: a slow or changing Chrome is transient, and every key takes the full join as before.)
    public static let holdingDenials: Set<BrowserTypingDenial> = [.blockedSite, .notNormal, .sensitiveField]
    /// An ordinary boundary (click, app or window switch, Tab): the live
    /// unit is parked and judged after the settle (`resolveParked`).
    public func boundary(_ reason: SealReason, at typedAt: UInt64, now: UInt64, focusMoved: Bool) {
        // fix/chrome-x2: Command-Return (or Control-Return) whose click save (`pointerDown`) could not prove the page (X
        // already closing its post window or changing route): the text parks as a send (`sendParkedAt`).
        let send = reason == .submitChord && sendBurst()
        noteDisruptive(at: typedAt)
        if session.seal(reason, now: now, focusMoved: focusMoved), send { sendParkedAt = now }
    }
    /// A mouse button went down while text is unfinished (Saturday test: a
    /// click lost website typing). The click may move focus to a button
    /// (Send, Post, Search) or another field, and a parked unit is saved only
    /// if a later join finds its field again, so the unit is saved now:
    /// - `result` is the click join (`anyFocus`), taken after the button went
    ///   down: every window normal, the same window list the burst started
    ///   with, the same window, tab, page and site as the last admitted key
    ///   (focus may have moved inside the page);
    /// - the unit is committed to the field of its last admitted key (every
    ///   key was admitted by a fresh join of it), stamped with the click
    ///   join's time; the gate checks policy, generation and site again.
    /// An Incognito or Guest window, or a blocked site, drops everything
    /// unsaved (invariant 6). Any other refusal (focus outside the page, a
    /// secure field, a changed page, a timeout) changes nothing: the click
    /// stays a boundary, as before. The click starts the quiet period.
    ///
    /// Review G12: a chorded Return (Command-Return or Control-Return sends in
    /// many web apps and may move focus to a button or away from the page)
    /// saves the same way, with its own `reason`.
    public func pointerDown(_ result: BrowserTypingJoinResult, at downAt: UInt64, now: UInt64, policy: CapturePolicy,
                            reason: SealReason = .pointer, write: (TypingCommit) throws -> Bool) rethrows -> TypingOutcome? {
        guard session.hasLive, let s = start, let l = last, s.sameBurst(as: l) else { return nil }
        if let denial = result.denial {
            guard [.notNormal, .blockedSite, .disabled].contains(denial) else { return nil }
            denied(denial, at: now); return .discarded(.unconfirmedFocus)
        }
        guard let p = result.proof, !p.light, p.checkedAt >= downAt, now >= p.checkedAt, now - p.checkedAt <= BrowserTypingTiming.proofTTLNanoseconds,
              p.windowList == s.windowList, p.origin == l.origin, p.windowID == l.windowID, p.tabID == l.tabID,
              p.documentID == l.documentID, p.targetIdentity == l.targetIdentity else { return nil }
        var field = BrowserTypingJoinProof(origin: l.origin, windowID: l.windowID, tabID: l.tabID, windowList: l.windowList,
                                           documentID: l.documentID, focusID: l.focusID, targetIdentity: l.targetIdentity,
                                           role: l.role, subrole: l.subrole, checkedAt: p.checkedAt)
        // fix/typing-e2e: the field's own metadata, so a Command-Return send keeps its field class, place and page title.
        field.sendField = l.sendField; field.sendPlace = l.sendPlace; field.pageTitle = l.pageTitle
        field.composeRoute = l.composeRoute; field.replyLabels = l.replyLabels
        let outcome = try session.commitLive(fresh: proof(field, policy: policy), reason: reason, policy: policy, now: now, write: write)
        noteDisruptive(at: downAt)
        return outcome
    }
    /// Esc: a search field's unfinished search is discarded; elsewhere it
    /// is a Tab-like boundary.
    public func escape(at typedAt: UInt64, now: UInt64) {
        noteDisruptive(at: typedAt)
        session.escape(now: now)
    }

    /// One key. `join` (the full join) is called at most once per join the
    /// key needs, after the key was typed; `read` (the key's characters) only
    /// after the join, the burst rules, the gate and the secret latch allow
    /// the key. Commits go to `write`.
    ///
    /// `light` (review G51) is the light per-key check: while a burst a full
    /// join started is open, a typed, deleted or accented key asks it first,
    /// and takes the full join only when it has no proof. Return, paste, a
    /// split and every save take the full join.
    public func key(_ intent: KeyIntent, join: () -> BrowserTypingJoinResult, light: () -> BrowserTypingJoinResult? = { nil },
                    held: () -> Bool? = { nil }, typedAt: UInt64, now: () -> UInt64,
                    policy: CapturePolicy, beforeEdit: (FocusProof, UInt64) -> Void = { _, _ in }, read: () throws -> String, write: (TypingCommit) throws -> Bool) rethrows -> BrowserTypingStep {
        // Review B5-2: a drop names only this key's own reason, never an earlier key's (a secret's refusal sets none).
        dropReason = nil
        func keyJoin() -> BrowserTypingJoinResult { (start != nil ? light() : nil) ?? join() }
        switch intent {
        case .edit, .insertText, .insert, .accent:
            // Codex 07:10 (field hold): the burst goes on while plain keys come less than `refusedHoldNanoseconds`
            // apart (the quiet period's dropped keys included).
            let holdBurst = fieldHeld && typedAt >= fieldHeldKeyAt && typedAt - fieldHeldKeyAt < BrowserTypingTiming.refusedHoldNanoseconds
                && episodeHeldSince.map { typedAt >= $0 && typedAt - $0 < BrowserTypingTiming.episodeHoldNanoseconds } != false
            if holdBurst { fieldHeldKeyAt = typedAt }
            // fix/web-textbox (battery): dropped whatever a join says; no join.
            if dropsUnread(typedAt: typedAt) {
                dropReason = heldUntil.map { typedAt < $0 } == true ? .held : .quiet
                start = nil; session.retract(); return .dropped
            }
            // Codex 07:10 (field hold): the box a full join refused as `field` still has focus, within the burst: the
            // key is dropped unread with no join, and (review FH-1) the quiet period starts again, as every refused
            // key's did before the hold (`noteDenied`). Focus left the box within the burst (a script's focus(), an
            // auto-advance, secure input): the key may have been typed in the refused box, so it is dropped unread too
            // and the hold ends with a denial quiet period (`noteDenied`, review 10:35 Q-1); the full join decides after it. A pause ends
            // the hold and the full join decides.
            if fieldHeld {
                // (nil: the join holds no box, e.g. the refusal was focus on a button: no hold, the full join decides.)
                if holdBurst, let same = held() {
                    let at = now()
                    dropReason = .held; session.retract()
                    // Review 10:35 Q-1: both ends are denial quiet (`noteDenied`), never recoverable by QF-1: focus left
                    // the box is a refusal-hold consequence at processing time, not a user boundary.
                    noteDenied(at: at)
                    fieldHeld = same
                    return .dropped
                }
                fieldHeld = false
            }
        default: break
        }
        switch intent {
        case .consume, .noop: return .ignored
        case .leave(let reason, _):
            boundary(reason, at: typedAt, now: now(), focusMoved: true); return .sealed
        case .retract:
            let result=join(),at=now()
            editedByShortcut(result,typedAt:typedAt,processedAt:at,policy:policy,beforeEdit:beforeEdit)
            session.retract(); noteDisruptive(at: typedAt); return .dropped
        case .split(let reason):
            return .committed(try commit(join(), typedAt: typedAt, processedAt: now(), reason: reason, policy: policy, write: write))
        case .redo, .paste, .submit:
            let reason: SealReason = intent == .submit ? .submit : intent == .paste ? .paste : .cursor
            let result=join(),at=now()
            if intent != .submit {editedByShortcut(result,typedAt:typedAt,processedAt:at,policy:policy,beforeEdit:beforeEdit)}
            let outcome = try commit(result, typedAt: typedAt, processedAt: at, reason: reason, policy: policy, write: write)
            noteDisruptive(at: typedAt)
            return .committed(outcome)
        case .edit(let op):
            let result = keyJoin(), at = now()
            let changed: Bool
            switch op { case .insert, .deleteBackward, .deleteForward, .cutSelection: changed = true; default: changed = false }
            guard let fp = admitted(result, typedAt: typedAt, processedAt: at, policy: policy, beforeEdit: changed ? beforeEdit : { _, _ in }) else { return .dropped }
            return try after(session.apply(op, proof: fp, policy: policy, eventAt: typedAt, now: at), result, typedAt: typedAt, at: at, policy: policy,
                             full: join, now: now, write: write)
        case .insertText(let text):
            return try insert(keyJoin(), typedAt: typedAt, now: now, policy: policy, full: join, beforeEdit: beforeEdit, write: write) { text }
        case .insert(let dead):
            return try insert(keyJoin(), typedAt: typedAt, now: now, policy: policy, full: join, beforeEdit: beforeEdit, write: write) { let raw = try read(); return dead.map { $0.compose(raw) } ?? raw }
        case .accent(let letter):
            let result = keyJoin(), at = now()
            guard let fp = admitted(result, typedAt: typedAt, processedAt: at, policy: policy, beforeEdit: beforeEdit) else { return .dropped }
            let step = session.apply(.deleteBackward(.character), proof: fp, policy: policy, eventAt: typedAt, now: at)
            guard step.commit == nil, step.decision.outcome == .allowed else {
                return try after(step, result, typedAt: typedAt, at: at, policy: policy, full: join, now: now, write: write)
            }
            return try after(session.insert(letter, proof: fp, policy: policy, eventAt: typedAt, now: at), result, typedAt: typedAt, at: at, policy: policy,
                             full: join, now: now, write: write)
        }
    }
    /// QF-17 bracketed design: one held key the bracket engine admitted, applied like `key` applies an allowed
    /// key. `intent` is `.insertText` (held characters), `.edit` or `.accent`. `rb`'s full-join result serves a
    /// size split's save (it started after the key).
    public func bracketedKey(_ intent: KeyIntent, ra: BrowserTypingJoinProof, rb: BrowserTypingJoinProof, typedAt: UInt64, now: UInt64,
                             policy: CapturePolicy, deferCommit: Bool = false, bSideSent: UInt64? = nil, beforeEdit: (FocusProof, UInt64) -> Void = { _, _ in },
                             write: (TypingCommit) throws -> Bool) rethrows -> BrowserTypingStep {
        dropReason = nil
        // Fail closed, as before: a key the burst can't admit retracts the unfinished unit (the route counts it lost,
        // `.admission`, and the retracted text `.unit`: QF-17 key accounting).
        guard admitBracketed(ra: ra, rb: rb, typedAt: typedAt, processedAt: now, bSideSent: bSideSent) else {
            dropReason = .stale; session.retract(); return .dropped
        }
        let result = BrowserTypingJoinResult.allowed(rb)
        let changed: Bool
        switch intent {
        case .insert, .insertText, .accent: changed = true
        case .edit(let op):
            switch op { case .insert, .deleteBackward, .deleteForward, .cutSelection: changed = true; default: changed = false }
        default: changed = false
        }
        guard let fp = gated(rb, processedAt: now, policy: policy, beforeEdit: { fp, _ in if changed {beforeEdit(fp, typedAt)} }) else { return .dropped }
        let full: () -> BrowserTypingJoinResult = { result }
        let clock: () -> UInt64 = { now }
        switch intent {
        case .insertText(let text):
            return try after(session.insert(text, proof: fp, policy: policy, eventAt: typedAt, now: now), result, typedAt: typedAt, at: now,
                             policy: policy, full: full, now: clock, deferCommit: deferCommit, write: write)
        case .edit(let op):
            return try after(session.apply(op, proof: fp, policy: policy, eventAt: typedAt, now: now), result, typedAt: typedAt, at: now,
                             policy: policy, full: full, now: clock, deferCommit: deferCommit, write: write)
        case .accent(let letter):
            let step = session.apply(.deleteBackward(.character), proof: fp, policy: policy, eventAt: typedAt, now: now)
            guard step.commit == nil, step.decision.outcome == .allowed else {
                return try after(step, result, typedAt: typedAt, at: now, policy: policy, full: full, now: clock, deferCommit: deferCommit, write: write)
            }
            return try after(session.insert(letter, proof: fp, policy: policy, eventAt: typedAt, now: now), result, typedAt: typedAt, at: now,
                             policy: policy, full: full, now: clock, deferCommit: deferCommit, write: write)
        default:
            return .ignored
        }
    }
    /// A shortcut can mutate a different field or an empty run. Its fresh
    /// metadata gate invalidates authority independently of burst/latch admission.
    private func editedByShortcut(_ result:BrowserTypingJoinResult,typedAt:UInt64,processedAt:UInt64,policy:CapturePolicy,
                                  beforeEdit:(FocusProof,UInt64)->Void) {
        guard let j=result.proof else {return}
        let fp=proof(j,policy:policy)
        guard session.typingGate(fp,policy,session.generation,processedAt).outcome == .allowed else {return}
        beforeEdit(fp,typedAt)
    }
    private func insert(_ result: BrowserTypingJoinResult, typedAt: UInt64, now: () -> UInt64, policy: CapturePolicy,
                        full: () -> BrowserTypingJoinResult, beforeEdit: (FocusProof, UInt64) -> Void,
                        write: (TypingCommit) throws -> Bool,
                        characters: () throws -> String) rethrows -> BrowserTypingStep {
        let at = now()
        guard let fp = admitted(result, typedAt: typedAt, processedAt: at, policy: policy, beforeEdit: beforeEdit) else { return .dropped }
        let text = try characters()
        return try after(session.insert(text, proof: fp, policy: policy, eventAt: typedAt, now: at), result, typedAt: typedAt, at: at, policy: policy,
                         full: full, now: now, write: write)
    }
    /// The join, the burst rules, the gate and the latch, before anything is read.
    private func admitted(_ result: BrowserTypingJoinResult, typedAt: UInt64, processedAt: UInt64, policy: CapturePolicy, beforeEdit: (FocusProof, UInt64) -> Void = { _, _ in }) -> FocusProof? {
        if let denial = result.denial { dropReason = .denied; denied(denial, at: processedAt); return nil }
        guard admitKey(result, typedAt: typedAt, processedAt: processedAt), let j = result.proof else { session.retract(); return nil }
        return gated(j, processedAt: processedAt, policy: policy, beforeEdit: { fp, _ in beforeEdit(fp, typedAt) })
    }
    /// The gate and the latch on an admitted key's proof.
    private func gated(_ j: BrowserTypingJoinProof, processedAt: UInt64, policy: CapturePolicy, beforeEdit: (FocusProof, UInt64) -> Void = { _, _ in }) -> FocusProof? {
        let fp = proof(j, policy: policy)
        let gate = session.typingGate(fp, policy, session.generation, processedAt)
        guard gate.outcome == .allowed else {
            dropReason = .gate
            session.refuse(gate, now: processedAt)
            if CaptureGate.typingDenyReasons.contains(gate.reason) { start = nil; last = nil; noteDenied(at: processedAt) } else { session.retract() }
            return nil
        }
        // Invalidate derived authority even when the secret latch withholds this key.
        beforeEdit(fp, processedAt)
        if session.admit(fp, now: processedAt) != nil { dropReason = .latch; return nil }
        return fp
    }
    private func after(_ step: TypingStep, _ result: BrowserTypingJoinResult, typedAt: UInt64, at: UInt64, policy: CapturePolicy,
                       full: () -> BrowserTypingJoinResult, now: () -> UInt64, deferCommit: Bool = false,
                       write: (TypingCommit) throws -> Bool) rethrows -> BrowserTypingStep {
        guard step.decision.outcome == .allowed else { return .dropped }
        // A size split or a caret move out of the run: commit now, with the
        // join just taken for this key (the burst is kept for the next key),
        // or a full join when that was a light check (a save needs one).
        guard let reason = step.commit else { return .typed }
        if deferCommit {
            // Stop/pause may still admit a pre-cutoff held key. Preserve an
            // automatic size/caret part until the finish obtains new authority;
            // never consume it through a writer that is intentionally disabled.
            session.deferCommit(reason, now: at)
            return .sealed
        }
        let kept = start
        let light = result.proof?.light == true
        let saving = light ? full() : result, savedAt = light ? now() : at
        let outcome = try commit(saving, typedAt: typedAt, processedAt: savedAt, reason: reason, policy: policy, write: write)
        if start == nil, kept != nil, saving.proof.map({ kept!.sameBurst(as: $0) }) == true { start = kept }
        return .committed(outcome)
    }

    /// Live save of the unfinished text (Return, a pause in typing, a size
    /// split, paste). Needs a fresh allowed join of the same burst. With no
    /// text only the boundary is noted (Return still ends a value).
    public func commit(_ result: BrowserTypingJoinResult, typedAt: UInt64?, processedAt: UInt64, reason: SealReason,
                       policy: CapturePolicy, write: (TypingCommit) throws -> Bool) rethrows -> TypingOutcome {
        // fix/chrome-x2: Return sends on a chat or search page, and the page may react before its join reads it (the
        // search page loads, the composer empties or loses focus). A refusal of that kind parks the burst's admitted
        // text as a send, judged after the settle (`resolveParked`), instead of dropping it.
        let sendable = reason == .submit && sendBurst()
        if let denial = result.denial {
            if sendable, Self.sendReactions.contains(denial) {
                noteDenied(at: processedAt); hold(denial, at: processedAt); start = nil
                if session.seal(.submit, now: processedAt, focusMoved: true) { sendParkedAt = processedAt; return .parked }
                return .discarded(.unconfirmedFocus)
            }
            denied(denial, at: processedAt); return .discarded(.unconfirmedFocus)
        }
        guard session.hasLive else {
            start = nil
            session.seal(reason, now: processedAt, focusMoved: false, proof: result.proof.map { proof($0, policy: policy) })
            return .none
        }
        guard save(result, typedAt: typedAt, processedAt: processedAt) != nil, let j = result.proof else {
            // An allowed join of another field or address of the page (the post window closed onto the timeline's box).
            if sendable, session.seal(.submit, now: processedAt, focusMoved: true) { sendParkedAt = processedAt; return .parked }
            session.retract(); return .discarded(.unconfirmedFocus)
        }
        let outcome = try session.commitLive(fresh: proof(j, policy: policy), reason: reason, policy: policy, now: processedAt, write: write)
        // A hard size cap continues the run in the same field.
        if session.hasLive { start = j }
        return outcome
    }
    /// The oldest due parked unit (all with `force`), after the settle.
    /// `result` is the fresh full join (nil when none could be taken) and
    /// `page` the fresh click join (`anyFocus`) taken right after it, only
    /// when the full join was denied `.field` (review G12, round 1: the full
    /// join goes first, so a click join that fails can't make it forget the
    /// page; the join compares that click join with the page from before the
    /// `.field` denial, `BrowserTypingJoin.departedPage`). The unit
    /// is saved to the field of its last admitted key when, on the same page
    /// (window, tab, page, window list and Chrome launch) as that key:
    /// - the full join finds focus in that field, or in another text field
    ///   it allowed (review G12: Tab to the next field of a form), which
    ///   passes the website gate as the destination; or
    /// - the full join finds focus on something that is not a text field (a
    ///   Send button, a link: `.field`) and the click join proved the page,
    ///   the window list and a focus that is not secure, with secure input
    ///   off: a departure within Chrome to a non-secure focus.
    /// Otherwise the unit is dropped, because a browser's focus can't be
    /// proven safe any other way. A password field (a secure subrole, secure
    /// input, or labels) is never such a destination: the username typed
    /// before it is dropped, as native typing does. Incognito or Guest, a
    /// sensitive field, a blocked site or typing off (either join) drops
    /// everything unsaved.
    public func resolveParked(_ result: BrowserTypingJoinResult?, page: BrowserTypingJoinResult? = nil, secureInput: Bool, now: UInt64,
                              policy: CapturePolicy, force: Bool = false, write: (TypingCommit) throws -> Bool) rethrows -> TypingOutcome? {
        guard let due = session.nextParkedDeadline, force || due <= now else { return nil }
        if let denial = page?.denial, [.notNormal, .blockedSite, .disabled].contains(denial) {
            denied(denial, at: now); return .discarded(.unconfirmedFocus)
        }
        let send = sendPending(now: now)
        var departure = DepartureState()
        if let denial = result?.denial, [.notNormal, .sensitiveField, .field, .blockedSite, .disabled].contains(denial) {
            guard denial == .field, !secureInput, let p = page?.proof, let l = last, samePage(p, l, now: now) || (send && sameTab(p, l, now: now)) else {
                denied(denial, at: now); return .discarded(.unconfirmedFocus)
            }
            departure = DepartureState(secureInput: .no, bundle: WebTypingGate.bundle, focusSecure: .no)
        } else if send, !secureInput, let denial = result?.denial, Self.sendReactions.contains(denial), let p = page?.proof, let l = last, sameTab(p, l, now: now) {
            // fix/chrome-x2: after a send the page may still be changing (`url`, `window`, `changed`): the click join proved
            // the same tab, every window normal and a focus that is not secure.
            departure = DepartureState(secureInput: .no, bundle: WebTypingGate.bundle, focusSecure: .no)
        }
        var destination: FocusProof?
        if let j = result?.proof, let l = last, samePage(j, l, now: now) || (send && sameTab(j, l, now: now)) {
            destination = proof(j, policy: policy)
        }
        return try session.resolveParked(destination: TypingDestination(proof: destination, departure: departure),
                                         secureInput: secureInput, policy: policy, now: now, force: force, write: write)
    }
    /// fix/chrome-x2: a send parked (`sendParkedAt`) no longer than `sendSettleNanoseconds` ago.
    public func sendPending(now: UInt64) -> Bool {
        guard let at = sendParkedAt else { return false }
        guard now >= at, now - at <= Self.sendSettleNanoseconds else { sendParkedAt = nil; return false }
        return true
    }
    /// The route's settle takes the click join after its full join when this says so: the full join refused focus as not
    /// a text field (review G12), or a send is pending and the full join was refused for a reason a page's reaction to it
    /// can cause (fix/chrome-x2).
    public func wantsPageJoin(_ result: BrowserTypingJoinResult?, now: UInt64) -> Bool {
        guard last != nil, let denial = result?.denial else { return false }
        return denial == .field || (sendPending(now: now) && Self.sendReactions.contains(denial))
    }
    /// fix/chrome-x2: a fresh full or click join of the same Chrome, window, tab, site and window list as the last
    /// admitted key `l`; the address within the site may differ (a send moved the page on). Never a light check.
    private func sameTab(_ j: BrowserTypingJoinProof, _ l: BrowserTypingJoinProof, now: UInt64) -> Bool {
        !j.light && j.origin == l.origin && j.windowID == l.windowID && j.tabID == l.tabID
            && j.targetIdentity == l.targetIdentity && j.windowList == l.windowList
            && now >= j.checkedAt && now - j.checkedAt <= BrowserTypingTiming.proofTTLNanoseconds
    }
    /// A fresh full or click join (never a light check) of the page and
    /// window list of the last admitted key `l`.
    private func samePage(_ j: BrowserTypingJoinProof, _ l: BrowserTypingJoinProof, now: UInt64) -> Bool {
        !j.light && j.origin == l.origin && j.windowID == l.windowID && j.tabID == l.tabID && j.documentID == l.documentID
            && j.targetIdentity == l.targetIdentity && j.windowList == l.windowList
            && now >= j.checkedAt && now - j.checkedAt <= BrowserTypingTiming.proofTTLNanoseconds
    }
}

/// fix/chrome-capture (diagnostics): why a key was dropped. `held`/`quiet`: the burst rules dropped it unread (a
/// privacy refusal's hold, the quiet period after a boundary); `denied`: the join said no; `late`: processed more
/// than `maxKeyLag` after it was typed; `stale`: its join is older than the key or than `proofTTL`; `otherBurst`: its
/// field isn't the burst's; `lightStart`: a light check can't start a burst; `gate`: the website gate refused it;
/// `latch`: a secret latch holds the field.
public enum BrowserTypingDrop: String, Sendable, CaseIterable { case held, quiet, denied, late, stale, otherBurst, lightStart, gate, latch }

/// fix/chrome-capture (QF-2): the shortcuts that switch away from the page (another app, window or tab, or the address
/// bar) and save the unfinished text at their key-down, like a click (`BrowserTypingBurst.pointerDown`): the save
/// takes a click join then, which must prove the same window, tab, page and window list as the last admitted key, so
/// the text is never saved from a window or tab the shortcut opens, and an Incognito or Guest window drops it. Without
/// it the unit was parked and its settle join, taken once Chrome was no longer in front or focus was in the address bar
/// or a new tab, dropped it. Anything else (Command-N, Command-Shift-N, Command-W, Command-Q, Command-Shift-T) stays a
/// parked boundary, as before.
public enum WebSwitchShortcut {
    /// Command-1 to Command-9 (a tab by position).
    static let digits: Set<Int64> = [18, 19, 20, 21, 23, 22, 26, 28, 25]
    public static func savesAtKeyDown(_ k: KeyStroke) -> Bool {
        guard !k.fn, !k.autorepeat else { return false }
        switch k.keyCode {
        case 48 where k.command && !k.control && !k.option: return true    // Command-Tab, Command-Shift-Tab: the app switcher
        case 48 where k.control && !k.command && !k.option: return true    // Control-Tab, Control-Shift-Tab: the next or previous tab
        case 50 where k.command && !k.control && !k.option: return true    // Command-`: the next window
        case 30, 33: return k.command && k.shift && !k.control && !k.option  // Command-Shift-] and [: the next or previous tab
        case 37: return k.command && !k.shift && !k.control && !k.option   // Command-L: the address bar
        case 17: return k.command && !k.shift && !k.control && !k.option   // Command-T: a new tab (never Command-Shift-T)
        case _ where digits.contains(k.keyCode): return k.command && !k.shift && !k.control && !k.option
        default: return false
        }
    }
}

/// fix/chrome-capture (QF-11, QF-3): a bounded look around the focused text field, deny-only, in the full join after
/// its labels, in both of its reads, around every kind of box typing is taken from (a one-line box, a text area, a
/// contenteditable box, a search field).
/// Up to `ancestors` ancestors of the field, up to and including the page's AXWebArea (review R9-1: when the walk
/// reaches the page within `ancestors` levels, the page's other children are scanned too; never above it), each one's other children
/// breadth first, nearest first, at most `maxNodes` nodes in all, and no container with more than `maxChildren`
/// children. The field is refused (`sensitiveField`) when that finds a secure text field or a control named like
/// "Show password". Reads a node's role, its subrole only for a text field, its title and description only for a
/// button-like control, and its children only for a container; never a value.
/// `clear` is bounded, never "the form is clean": no secure field or reveal control among the first `maxNodes` nodes
/// within `ancestors` ancestors. Codex 07:10 (fail-closed nested web areas): a nested AXWebArea (an iframe's page)
/// met by the scan is opened too, after the page (review Q6-1: deferred, so frames never change what the page alone
/// finds), inside what is left of the same node budget and child cap. The same reads as on the page (roles, a text
/// field's subrole, a control's names, children; never a value); a secure field or a reveal control in it refuses the
/// field (`sensitiveField`). Stated cost: frames near the field spend the node budget, so a field beside a large frame
/// (a captcha, a comment widget, a payment frame, a video embed) is refused (`exhausted`: `field`). Stated cost of
/// R9-1: a field within 3 levels of a page with more than `maxNodes` other nodes is refused (`field`). `exhausted` (the node budget ran out first) and `unreadable` (a role or
/// children read failed, or a container has more than `maxChildren` children) can't show there is no such neighbour:
/// both refuse the join as `field` (fail closed; review C2, C3), whatever the box: a composer on a page with more than
/// `maxNodes` nodes or a container of more than `maxChildren` children within `ancestors` ancestors is refused (a
/// stated loss of capture). `late`: the join's time budget ran out (`timeout`).
/// C1 closure (Codex direction): a field deeper than `ancestors` below its page is no longer scanned only 3 levels up: every
/// ancestor up to the page is scanned, nearest first, in the same budget (the whole page; frames last), so a password
/// field or a reveal control anywhere on a page that fits the budget refuses the field. Was (stated cost, large on real
/// sites): a deep field on a page with more than `maxNodes` nodes around its ancestry was refused (`field`): X, Reddit,
/// Gmail, Google Docs, most app-like pages. fix/chrome-large-pages: such an `exhausted` walk is now answered by the
/// bounded page search (`search`, `ChromeAXAccess.formSearchRecoveryEnabled`), in the same join deadline.
public enum BrowserFormScanResult: String, CaseIterable, Sendable { case clear, exhausted, password, reveal, unreadable, late }
public enum BrowserFormScan {
    public static let ancestors = 3
    public static let maxNodes = 64
    public static let maxChildren = 256
    /// Roles whose children are never read: their contents are text or a control's own parts. (A nested AXWebArea,
    /// an iframe's page, is opened after the page: Codex 07:10, review Q6-1.)
    static let leaves: Set<String> = ["AXTextArea", "AXTextField", "AXStaticText", "AXImage", "AXButton", "AXCheckBox",
                                      "AXRadioButton", "AXLink", "AXComboBox", "AXPopUpButton", "AXMenuButton", "AXSlider", "AXHeading"]
    /// Roles a text field (or a password field) may have: the scan reads their subrole (review 10:48).
    static let textLike: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    static let controls: Set<String> = ["AXButton", "AXCheckBox", "AXLink", "AXToggle", "AXSwitch", "AXMenuButton"]
    static let secretWords = ["password", "passcode", "passphrase", "passwort", "contraseña", "mot de passe", "senha", "wachtwoord"]
    static let revealWords = ["show", "hide", "reveal", "view", "unmask", "mask", "toggle", "display", "anzeigen", "mostrar", "afficher"]
    /// A control's name that shows or hides a password ("Show password", "Hide password", "Toggle password visibility").
    public static func revealName(_ raw: String) -> Bool {
        guard raw.utf8.count <= 256 else { return false }
        let l = raw.lowercased()
        return secretWords.contains { l.contains($0) } && revealWords.contains { l.contains($0) }
    }
    public static let searchLimit = maxNodes + 1
    /// Every secret word has a fixed search fragment; control names are still checked with revealName.
    public static let searchWords = ["pass", "contrase", "senha", "wachtwoord"]
    public static func scan<Node>(chain: [Node], ax: ChromeAXAccess<Node>, late: () -> Bool) -> BrowserFormScanResult {
        let walked = walk(chain: chain, ax: ax, late: late)
        // The completed walk's password/reveal/unreadable/late answers are never downgraded.
        // Child-cap refusals remain unchanged: an unreadable subtree cannot prove search completeness.
        guard walked == .exhausted, ax.formSearchRecoveryEnabled else { return walked }
        switch search(chain: chain, ax: ax, late: late) {
        case .clear: return .clear
        case .password: return .password
        case .reveal: return .reveal
        case .late: return .late
        case .exhausted, .unreadable: return walked
        }
    }
    /// C-1..C-7. Search only the page already in the chain; no count-only acceptance, value reads or strings saved.
    /// This is deliberately exposed for bounded QA; scan still enforces the production recovery gate above.
    public static func search<Node>(chain: [Node], ax: ChromeAXAccess<Node>, late: () -> Bool) -> BrowserFormScanResult {
        guard let focus = chain.first else { return .unreadable }
        var pages: [Node] = []
        for node in chain {
            if late() { return .late }
            guard let role = ax.role(node) else { return .unreadable }
            if role == "AXWebArea" { pages.append(node) }
        }
        guard pages.count == 1, let page = pages.first else { return .unreadable }
        if late() { return .late }
        guard let pid = ax.owner(page) else { return .unreadable }
        if late() { return .late }
        guard ax.owner(focus) == pid else { return .unreadable }
        if late() { return .late }
        let editable = ax.editableAncestor(focus)
        if late() { return .late }
        guard let fields = ax.formSearch(page, .textFields, searchLimit), fields.count < searchLimit else { return .unreadable }
        if late() { return .late }
        var sentinel = false
        for node in fields {
            if late() { return .late }
            guard ax.owner(node) == pid else { return .unreadable }
            if late() { return .late }
            guard let role = ax.role(node) else { return .unreadable }
            if role.lowercased().contains("secure") { return .password }
            if late() { return .late }
            guard let subrole = ax.subrole(node) else { return .unreadable }
            if subrole.lowercased().contains("secure") { return .password }
            if role == "AXGroup" {
                if late() { return .late }
                guard let ancestor = ax.editableAncestor(node), ax.equal(ancestor, node) else { return .unreadable }
            } else if !textLike.contains(role) { return .unreadable }
            sentinel = sentinel || ax.equal(node, focus) || editable.map { ax.equal(node, $0) } == true
        }
        guard sentinel else { return .unreadable }
        let searchControls: Set<String> = ["AXButton", "AXCheckBox", "AXLink"]
        for word in searchWords {
            if late() { return .late }
            guard let matches = ax.formSearch(page, .revealControls(word), searchLimit), matches.count < searchLimit else { return .unreadable }
            if late() { return .late }
            for node in matches {
                if late() { return .late }
                guard ax.owner(node) == pid else { return .unreadable }
                if late() { return .late }
                guard let role = ax.role(node) else { return .unreadable }
                if role.lowercased().contains("secure") { return .password }
                if late() { return .late }
                // C-7 applies even when a malformed/unknown-key result has an unexpected role.
                guard let subrole = ax.subrole(node) else { return .unreadable }
                if subrole.lowercased().contains("secure") { return .password }
                guard searchControls.contains(role) else { return .unreadable }
                if late() { return .late }
                let names = ax.controlNamesForForm(node, late: late)
                if late() { return .late }
                guard let names else { return .unreadable }
                if names.contains(where: revealName) { return .reveal }
            }
        }
        return late() ? .late : .clear
    }
    private static func walk<Node>(chain: [Node], ax: ChromeAXAccess<Node>, late: () -> Bool) -> BrowserFormScanResult {
        var seen = 0
        // Codex 07:10, review Q6-1: nested AXWebAreas (iframes' pages) met on the page are deferred and opened only
        // after every level of the page was scanned, in the same node budget and child cap. Frames then never change
        // what the page alone finds (a page's password field behind a large frame stays `password`, not `exhausted`),
        // and can only turn `clear` into a refusal. Was (d98c2c9): frame contents shared the page's breadth-first
        // queue, so a password field the scan used to reach could fall behind them (`exhausted`: `field`, which lets a
        // parked draft from the field before be saved where `sensitiveField` drops it).
        var frames: [Node] = []
        /// One node: nil to go on, or the scan's answer. A container's children join `queue`; a nested page joins
        /// `frames` while the page itself is being scanned.
        func visit(_ node: Node, _ queue: inout [Node], page: Bool) -> BrowserFormScanResult? {
            guard seen < maxNodes else { return .exhausted }
            seen += 1
            guard let role = ax.role(node) else { return .unreadable }
            if role.lowercased().contains("secure") { return .password }
            // Review 10:48 (datalist password): `<input type=password list=...>` is an AXComboBox with the subrole
            // AXSecureTextField. Was: the subrole was read only for AXTextField, and AXComboBox is a leaf, so such a
            // password field was never seen. The subrole of every text-field-like role is read now.
            if textLike.contains(role) {
                guard let sub = ax.subrole(node) else { return .unreadable }
                return sub.lowercased().contains("secure") ? .password : nil
            }
            // Review Q6-2: control names ("Show password") are read inside frames too (deny-only).
            if controls.contains(role) {
                if late() { return .late }
                let names = ax.controlNamesForForm(node, late: late)
                if late() { return .late }
                guard let names else { return .unreadable }
                return names.contains(where: revealName) ? .reveal : nil
            }
            guard !leaves.contains(role) else { return nil }
            if page, role == "AXWebArea" { frames.append(node); return nil }
            guard let more = ax.children(node), more.count <= maxChildren else { return .unreadable }
            queue += more
            return nil
        }
        // C1 closure (Codex direction: close gaps conservatively; the level-4 password gap): the levels no longer stop at `ancestors`. A field deeper than
        // `ancestors` below its page gets the rest of its ancestors scanned too, nearest first, up to and including the
        // page (so the whole page, in the same node budget; frames still last). Was: levels 1...ancestors only, so a
        // password field 4 or more levels up was never seen (qf17-level4-password: 6 forbidden keys saved). A deeper
        // level is read only while the join has time and the budget has room (`late`, `exhausted`: both refuse).
        for level in 1..<max(chain.count, 1) {
            let root = chain[level]
            if level > ancestors {
                if late() { return .late }
                guard seen < maxNodes else { return .exhausted }
            }
            guard let rootRole = ax.role(root) else { return .unreadable }
            if rootRole == "AXWindow" { break }
            // Review R9-1 (QF-17 implementer's r9 patch, reviewed and approved 06:37/07:00): the walk reached the page itself within
            // `ancestors` levels. The page's other children are the rest of the page: scan them too, with the same
            // shared node budget and child cap (a larger page is `exhausted`: denied). Was: stop here, so a password
            // field that is a direct child of the AXWebArea, or any field that sits directly under the page, was never
            // scanned. The page is the last level scanned.
            let atPage = rootRole == "AXWebArea"
            guard let kids = ax.children(root), kids.count <= maxChildren else { return .unreadable }
            var queue = kids.filter { !ax.equal($0, chain[level - 1]) }
            var i = 0
            while i < queue.count {
                if late() { return .late }
                let node = queue[i]; i += 1
                if let answer = visit(node, &queue, page: true) { return answer }
            }
            if atPage { break }
        }
        // The deferred frames, one after another (a frame inside a frame is opened in turn), in what is left of the
        // budget. Review Q7-1 (speed): a frame's children are read only while the join has time and the budget has
        // room, after the frames before it were scanned (was: every deferred frame's children first, with no check:
        // up to about 63 reads on the main thread before any was visited). Out of time or budget: refused.
        var queue: [Node] = []
        var i = 0
        for frame in frames {
            if late() { return .late }
            guard seen < maxNodes else { return .exhausted }
            guard let kids = ax.children(frame), kids.count <= maxChildren else { return .unreadable }
            queue += kids
            while i < queue.count {
                if late() { return .late }
                let node = queue[i]; i += 1
                if let answer = visit(node, &queue, page: false) { return answer }
            }
        }
        return .clear
    }
}

/// What one key did (for the host's timers and for checks).
public enum BrowserTypingStep: Equatable {
    /// Nothing to do (a dead key, a copy shortcut).
    case ignored
    /// The key was not recorded: a join denial, a late key, the quiet
    /// period, the gate or a secret latch. Nothing was read.
    case dropped
    /// The key changed the unfinished text.
    case typed
    /// A boundary: the text was parked for the settle.
    case sealed
    case committed(TypingOutcome)
}

/// fix/typing-e2e (L5): the place a website typing row is titled with. Exactly the title Chrome page history saves for
/// the same page (`ChromePageTitle.clean`: no unread counter, no placeholder or address as a title), so the typing lands
/// in the page's own moment ("PR #418 …", "Home / X") instead of a moment of its own named after the site. "" (the row
/// then keeps the site) wherever page history keeps the site only: search, email and chat pages, message pages on
/// social sites, and blocked pages. Read from the join's transient window title; the address is never kept.
public enum WebTypingTitle {
    public static func clean(_ raw: String, url: String, origin: String) -> String {
        var t = ChromeWindowMatching.baseName(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        for suffix in [" - Google Chrome", " – Google Chrome"] where t.hasSuffix(suffix) { t = String(t.dropLast(suffix.count)) }
        switch BrowserSites.pageDecision(url, userBlocked: []) {
        case .record: break
        // Webmail (fix/typing-e2e 7c): the open thread's subject, like Mail's window title, or nothing.
        case .siteOnly where SendRules.surface(bundle: WebTypingGate.bundle, host: BrowserSites.host(of: origin)) == "email"
                             && !BrowserSites.messagePath(host: BrowserSites.host(of: origin) ?? "", path: URLComponents(string: url)?.path ?? ""):
            t = emailSubject(t)
            // email-1003: a subject that reads like a code, password, sign-in, security or bank email is never a place.
            if TypedSecretScrubber.sensitiveSubject(t) != nil { return "" }
        default: return ""
        }
        guard var title = ChromePageTitle.clean(t, origin: origin, url: url) else { return "" }
        // The row's place fits `WebTypedRow.valid` (at most 256 bytes).
        while title.utf8.count > 256 { title.removeLast() }
        return title
    }
    static let mailboxNames: Set<String> = ["inbox", "sent", "sent mail", "sent items", "drafts", "draft", "starred", "snoozed", "important",
        "all mail", "spam", "junk", "junk email", "trash", "bin", "deleted items", "archive", "scheduled", "outbox", "search results", "mail",
        "compose", "compose mail", "new message", "gmail", "outlook", "yahoo mail", "proton mail", "icloud mail", "fastmail", "calendar", "contacts"]
    /// A webmail tab title's first part when it is a thread's subject ("Re: Pricing - me@example.com - Gmail" is
    /// "Re: Pricing"); "" for a mailbox or app name ("Inbox (3)", "Mail"), or any part with an address in it.
    static func emailSubject(_ raw: String) -> String {
        var first = raw.components(separatedBy: " - ").first ?? ""
        first = first.components(separatedBy: " – ").first ?? ""
        first = first.components(separatedBy: " | ").first ?? ""
        first = first.replacingOccurrences(of: #"\s*\(\d{1,5}\+?\)\s*"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !first.isEmpty, !first.contains("@"), !mailboxNames.contains(first.lowercased()) else { return "" }
        return first
    }
}

#if DAYDREAM_OWNER_TYPING
// MARK: - The saved row

/// One website typing row: the words (sealed by the store), the site, the
/// page's title where Chrome page history saves it (fix/typing-e2e L5,
/// `WebTypingTitle`) and the join's window, tab, page and field IDs. Never the
/// path, the query or a field label. Cloud summaries get the title cleaned
/// (`NoteAudience.cloudView`, fix/sx-all) with the site.
public enum WebTypedRow {
    public static let provider = "chrome-typing-join-v1"
    /// fix/chrome-x2 (owner, 2026-10-03: "the owner wants searches captured"): a search the person ran, read from the
    /// search results page's own address by Chrome page history (`WebSearchQuery`), whether it was typed in the page's
    /// box or in Chrome's address bar (which the join refuses: no web page holds it, `join.frame`). Its proof is the page
    /// read's normal-window check, not a field join: `focusedRole` is `searchRole`, never a field's role.
    public static let searchProvider = "chrome-search-url-v1"
    public static let searchRole = "searchResultsPage"
    public static let app = "Google Chrome"
    public static func evidence(_ c: TypingCommit, id: String, policyRevision: String, wallTime: Date, now: UInt64, pasted: Bool = false,
                                recipient: String? = nil) -> Evidence? {
        guard c.proof.bundle == WebTypingGate.bundle, let origin = BrowserSites.origin(c.proof.url), origin == c.proof.url,
              let host = BrowserSites.host(of: origin) else { return nil }
        let at = iso(wallTime)
        let started = wallTime.addingTimeInterval(-Double(now >= c.startedAt ? now - c.startedAt : 0) / 1_000_000_000)
        var proof = BrowserVerification(mode: "normal", windowID: c.proof.windowID, tabID: c.proof.tabID, focusedRole: c.proof.role,
                                        checkedAt: at, provider: provider)
        proof.documentID = c.proof.documentID; proof.focusID = c.proof.focusID; proof.policyRevision = policyRevision
        // The page's title as page history saves it, or the site (`BrowserTypingJoin.focusProof`).
        let place = c.proof.place.isEmpty || c.proof.place.utf8.count > 256 ? host : c.proof.place
        var e = Evidence(id: id, at: at, kind: "keyboard.text_input", app: app, bundle: WebTypingGate.bundle, title: place, url: origin,
                         text: c.text, browserVerification: proof)
        e.captureProvenance = NativeCaptureProvenance(policyRevision: policyRevision, classifierVersion: UnitClassifier.version,
            windowID: c.proof.windowID, focusID: c.proof.focusID, checkedAt: at, generation: c.proof.generation,
            unit: TypedUnitProvenance(runID: c.runID, part: c.part, sealReason: c.reason.rawValue, startedAt: iso(started),
                                      keys: c.withheld > 0 ? nil : c.keys, edits: c.withheld > 0 ? nil : c.edits, withheld: c.withheld))
        // summaries/v3 (spec §3, §4): the send facts, from the host, the field class and composer place the join read.
        // fix/typing-e2e: webmail's To-field name (`RecipientMemory`, the route's) for the email units after it.
        let facts = SendRules.facts(bundle: c.proof.bundle, host: host, title: host, field: c.proof.sendField.isEmpty ? "unknown" : c.proof.sendField,
                                    composerPlace: c.proof.sendPlace.isEmpty ? nil : c.proof.sendPlace, recipient: recipient, seal: c.reason)
        e.captureProvenance?.unit?.apply(facts, pasted: pasted)
        return e
    }
    /// The only shape a website typing row may have (write and read time).
    public static func valid(_ e: Evidence) -> Bool {
        guard e.bundle == WebTypingGate.bundle, e.kind == "keyboard.text_input", e.app == app, let v = e.browserVerification,
              v.provider == provider || v.provider == searchProvider, v.mode == "normal", ChromeAppleEvents.validID(v.windowID), ChromeAppleEvents.validID(v.tabID),
              v.provider == provider ? WebTypingGate.roles.contains(v.focusedRole) : v.focusedRole == searchRole, UUID(uuidString: v.documentID ?? "") != nil, UUID(uuidString: v.focusID ?? "") != nil,
              let revision = v.policyRevision, !revision.isEmpty, revision.utf8.count <= 256,
              let observed = timestamp(e.at), let checked = timestamp(v.checkedAt), abs(observed.timeIntervalSince(checked)) <= 1,
              !e.secure, !e.privateWindow, e.captureProvenance != nil, e.title.utf8.count <= 256,
              let origin = BrowserSites.origin(e.url), e.url == origin || e.url == origin + "/",
              let host = BrowserSites.host(of: origin), !BrowserSites.blockedByDefault(host: host) else { return false }
        // A search row: only on a search engine's host, titled with the site only, and the query only (one line).
        if v.provider == searchProvider {
            guard WebSearchQuery.engine(host: host) != nil, e.title == host, !e.text.isEmpty, e.text.utf8.count <= WebSearchQuery.maxBytes,
                  !e.text.contains(where: { $0.isNewline }), e.captureProvenance?.unit?.sealReason == SealReason.submit.rawValue else { return false }
        }
        return true
    }
    /// fix/chrome-x2: the row for a search the page read found (`WebSearchQuery.query`), saved like a search typed in the
    /// page's box and sent with Return ("Searched Google for '…'"): the words, the site only, and the page read's window
    /// and tab. The store's checks still apply (typing pause, site choices: Search and AI, the secret scrubber, sealing).
    public static func searchEvidence(query: String, engine: String, origin: String, windowID: String, tabID: String, id: String,
                                      policyRevision: String, generation: UInt64, wallTime: Date) -> Evidence? {
        guard let o = BrowserSites.origin(origin), o == origin, let host = BrowserSites.host(of: origin), WebSearchQuery.engine(host: host) == engine,
              !query.isEmpty, query.utf8.count <= WebSearchQuery.maxBytes else { return nil }
        let at = iso(wallTime)
        var proof = BrowserVerification(mode: "normal", windowID: windowID, tabID: tabID, focusedRole: searchRole, checkedAt: at, provider: searchProvider)
        proof.documentID = UUID().uuidString; proof.focusID = UUID().uuidString; proof.policyRevision = policyRevision
        var e = Evidence(id: id, at: at, kind: "keyboard.text_input", app: app, bundle: WebTypingGate.bundle, title: host, url: origin,
                         text: query, browserVerification: proof)
        e.captureProvenance = NativeCaptureProvenance(policyRevision: policyRevision, classifierVersion: UnitClassifier.version,
            windowID: windowID, focusID: proof.focusID ?? "", checkedAt: at, generation: generation,
            unit: TypedUnitProvenance(runID: UUID().uuidString, part: 0, sealReason: SealReason.submit.rawValue, startedAt: at,
                                      keys: nil, edits: nil, withheld: 0))
        e.captureProvenance?.unit?.apply(SendRules.facts(bundle: WebTypingGate.bundle, host: host, title: host, field: "search", seal: .submit), pasted: false)
        return valid(e) ? e : nil
    }
}

/// fix/chrome-x2: the query of a search engine's results page, from its address (the page read's step 4, which already
/// has it and otherwise drops it). Only the engines below, only their results path and query parameter; nothing else of
/// the address. The query is cleaned (whitespace, one line, at most `maxBytes`) and refused when it looks secret
/// (`Privacy.secret`), is a code of digits only (a one-time code), or holds an email address.
public enum WebSearchQuery {
    /// claude/search-1005: one parser for both: page history's search rows (`SearchPage`, every build) and this typed
    /// search row read the same engines, results paths, parameters and refusals.
    public static let maxBytes = SearchPage.maxBytes
    /// The engine's name for a search host, or nil.
    public static func engine(host: String) -> String? { SearchPage.engine(host: host) }
    public static func query(_ url: String) -> (engine: String, query: String)? { SearchPage.query(url) }
}

extension TypedTextPolicy {
    /// The store's check for a website typing row (defence in depth; the
    /// owner build's ingest calls it): a valid join row, Google Chrome not
    /// excluded, and its site allowed now by the block lists and the
    /// person's choices (host rule).
    public func permitsWebsiteRow(_ e: Evidence, settings: PrivacySettings, expanded: Bool = TypingRelease.open) -> Bool {
        guard WebTypedRow.valid(e), !settings.blockedApps.contains(e.bundle), !PrivacySettings.sensitiveApps.contains(e.bundle),
              let host = BrowserSites.host(of: e.url) else { return false }
        // A messaging site is Messages and email on every page (review F1).
        // The host rule says so too; it is named here as well, so a later
        // change to the table can't open it at the store.
        guard !BrowserTypingSites.messagingSite(host: host) || categories.messagesAndEmail else { return false }
        return BrowserTypingSiteRules(policy: self, settings: settings, expanded: expanded).permits(host: host)
    }
    /// Whether a website row saved before this build may stay (the store's
    /// one-time launch settle). Earlier owner builds saved every page of a
    /// messaging site (a Messenger pop-up on facebook.com/, LinkedIn's
    /// overlay on /feed/, a webmail host) as Other websites or Search and AI
    /// while Messages and email was off; while it is still off, those rows go.
    /// Every other row stays: later switch changes never delete words.
    public func keepsEarlierWebsiteRow(_ e: Evidence) -> Bool {
        guard e.browserVerification?.provider == WebTypedRow.provider, let host = BrowserSites.host(of: e.url) else { return true }
        return !BrowserTypingSites.messagingSite(host: host) || categories.messagesAndEmail
    }
}

/// The store's rules for website typing rows (`MemoryStore.websiteRows`).
struct WebsiteTypingRowRules: WebsiteTypingRows {
    func permits(_ e: Evidence, typed: TypedTextPolicy, settings: PrivacySettings) -> Bool { typed.permitsWebsiteRow(e, settings: settings) }
    func keeps(_ e: Evidence, typed: TypedTextPolicy) -> Bool { typed.keepsEarlierWebsiteRow(e) }
}

/// Owner build: honest status lines while website typing exists.
public enum WebTypingText {
    /// The recording reason (replaces "…what you type in browsers is never saved.").
    public static let recording = "Recording apps. Chrome page titles and sites are saved only if you turn them on. What's on web pages is never saved. What you type on websites in Google Chrome is saved only while typing and Web pages in Chrome are both on, never on blocked sites or in Incognito or Guest windows."
    /// The "Web pages in Chrome" card's line (owner build, consent version 2): the card must not say
    /// typing is never saved in the build that saves it.
    public static let chromeCard = "What you type on websites in Google Chrome is saved while typing is on and a website category is on in Typing, never on blocked sites or in Incognito or Guest windows."
    /// The Accessibility status line for browser windows.
    public static let browserStatus = "Browser windows aren't read here. What's on web pages is never saved. What you type on websites in Google Chrome is saved only while typing and Web pages in Chrome are both on, never on blocked sites or in Incognito or Guest windows."
    /// Whether website typing records in the front app now: Google Chrome,
    /// not excluded, at least one website switch on, and the last join in
    /// this Chrome window allowed typing (`WebTypingStatus`). Before the first
    /// key, and after an Incognito or Guest window, a blocked site, a missing
    /// permission or anything else the join refused, the dot is not shown.
    public static func mayRecord(frontmostBundle: String, policy: TypedTextPolicy, blockedApps: [String], expanded: Bool = TypingRelease.open,
                                 joined: WebTypingJoinState = WebTypingStatus.current) -> Bool {
        let c = policy.categories
        return expanded && frontmostBundle == WebTypingGate.bundle && !blockedApps.contains(frontmostBundle)
            && !PrivacySettings.sensitiveApps.contains(frontmostBundle)
            && (c.searchAndAI || c.writing || c.messagesAndEmail || c.otherWebsites)
            && joined == .allowed
    }
}

/// What the last website typing join said, for the menu-bar dot only:
/// allowed or not. Never the site, the window or the reason (a reason would
/// show when an Incognito window was open). `WebTypingRoute` sets it after
/// each join; leaving Chrome, a click and a shortcut in Chrome (a new window,
/// tab or page may be in front) make it unknown again.
public enum WebTypingJoinState: Equatable, Sendable { case unknown, allowed, denied }
public enum WebTypingStatus {
    private static let lock = NSLock()
    private static var value: WebTypingJoinState = .unknown
    public static var current: WebTypingJoinState { lock.lock(); defer { lock.unlock() }; return value }
    /// Each change posts `.typingIndicatorInputsChanged` (the app refreshes its
    /// menu). Once a join has judged the front window, an app switch or a click
    /// (`TypingFocus.mayHaveMoved`) makes it unknown again.
    public static func set(_ state: WebTypingJoinState) {
        lock.lock(); let changed = value != state; value = state; lock.unlock()
        if state != .unknown { TypingFocus.listen { WebTypingStatus.set(.unknown) } }
        guard changed else { return }
        let post = { NotificationCenter.default.post(name: .typingIndicatorInputsChanged, object: nil) }
        if Thread.isMainThread { post() } else { DispatchQueue.main.async(execute: post) }
    }
}
#endif
#endif
