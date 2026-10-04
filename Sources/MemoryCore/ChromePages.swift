import Foundation
import HistoryCore

// Chrome page history: the pure part (public build).
//
// What is read, in this order, from the one Chrome process that is in front:
// 1. the ID of every window;
// 2. the mode of every window. Any Incognito or Guest window (Guest reports
//    "incognito") or any unknown answer means nothing is read or saved;
// 3. the active tab of the front window, then its address. The address is
//    judged by BrowserSites and dropped: the row keeps the origin, and on this
//    Mac only the page's own link (`BrowserSites.pageLink`: no login, token,
//    tracking or search part; none for search, email and chat pages). A search
//    engine's results page keeps its search words as the row's title
//    (claude/search-1005, owner decision 2026-10-04), never the address;
// 4. the tab title, only for pages that keep a title (chat pages keep the site
//    only and their title is never asked for; an email page's only while "Save
//    email subjects" is on; a search engine's results page's only when its
//    address holds no search words: claude/search-1005, `SearchPage`);
// 5. the window list, every mode, the tab and the address again. Any change
//    means nothing is saved.
// No page text, field, click or background tab is read or kept, and no query
// or fragment beyond what `BrowserSites.pageLink` allows (a YouTube video's
// v, t and list; a plain section anchor). The Apple Event transport lives in MacMemApp;
// everything here is testable with a scripted fake.

/// Which Chrome may be read: Google Chrome stable, signed by Google.
public enum ChromePageTarget {
    public static let bundleID = "com.google.Chrome"
    public static let teamID = "EQHXZ8M8AV"
    /// Google's Developer ID for Chrome (stable channel only). Checked read-only
    /// against the installed Chrome 153 with `codesign --verify -R`.
    public static let requirement = "identifier \"com.google.Chrome\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = \"EQHXZ8M8AV\""
}

/// One running `com.google.Chrome` application process, as the Chrome paths see it before anything is asked of it.
/// Metadata only: the process's activation policy, whether it owns any ordinary window (a window-list read of owner
/// and layer, never a title), whether it is in front, and when it started.
public struct ChromeProcess: Equatable, Sendable {
    public var pid: Int32
    /// NSApplication.ActivationPolicy.regular (a Dock app).
    public var regular: Bool
    /// Owns at least one layer-0 window, on screen or not (a headless Chrome owns none).
    public var windows: Bool
    public var frontmost: Bool
    /// Seconds since 1970 the process started (launch date, else the kernel's start time); nil when unknown.
    public var started: Double?
    public init(pid: Int32, regular: Bool, windows: Bool, frontmost: Bool, started: Double?) {
        self.pid = pid; self.regular = regular; self.windows = windows; self.frontmost = frontmost; self.started = started
    }
}

/// Which Chrome process is the person's (live test, build 7): a headless or automation Chrome (Puppeteer,
/// Playwright, `--headless`) is a second process with the same bundle ID, no launch date and no window. Picking the
/// first process, or counting it, left page history and Chrome typing refusing the person's own Chrome.
/// The rule: the process in front is always the person's; any other process that is not a regular app, or owns no
/// window at all, is a background instance and neither chosen nor counted. The chosen process's own signature and
/// launch identity are then checked exactly as before (the sender's `signatureValid`).
public enum ChromeProcesses {
    public static func background(_ p: ChromeProcess) -> Bool { !p.frontmost && (!p.regular || !p.windows) }
    /// The person's Chrome processes (normally one; two when a second profile folder runs with windows).
    public static func user(_ all: [ChromeProcess]) -> [ChromeProcess] { all.filter { !background($0) } }
    /// The one to check: the frontmost Chrome; else the newest user process. nil when none is the person's.
    public static func chosen(_ all: [ChromeProcess]) -> ChromeProcess? {
        if let front = all.first(where: \.frontmost) { return front }
        return user(all).max { ($0.started ?? 0, $0.pid) < ($1.started ?? 0, $1.pid) }
    }
}

/// When a process started, for a launch identity (pid + start + bundle ID) that a reused PID never matches. macOS
/// leaves `NSRunningApplication.launchDate` nil for apps it didn't launch through Launch Services (Messages and
/// Finder reopened at login, a headless Chrome): the kernel's start time stands in then (live test, build 7).
public enum ProcessStart {
    /// The kernel's start time of `pid` in seconds since 1970, or nil when it can't be read (or reads as zero).
    public static func kernelSeconds(pid: Int32) -> Double? {
        guard pid > 0 else { return nil }
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size >= MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else { return nil }
        let t = info.kp_proc.p_un.__p_starttime
        let seconds = Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000
        return seconds > 0 ? seconds : nil
    }
    /// The launch date when macOS has one, else the kernel's start time.
    public static func seconds(launchDate: Date?, pid: Int32) -> Double? {
        launchDate.map(\.timeIntervalSince1970) ?? kernelSeconds(pid: pid)
    }
}

/// Everything page history may ask Chrome. Each case is one `core/getd` of one
/// allowlisted property, addressed by window and tab ID (never by position),
/// except `windowIDs`, which asks only for the IDs of every window.
public enum ChromePageRequest: Equatable, Sendable {
    case windowIDs                 // ID of every window
    case mode(String)              // mode of window id W
    case activeTabID(String)       // ID of active tab of window id W
    case tabURL(String, String)    // URL of tab id T of window id W
    case tabTitle(String, String)  // pnam of tab id T of window id W

    /// The audited object specifier, or nil. Built only by `ChromeAppleEvents`.
    public var specifier: NSAppleEventDescriptor? {
        let built: NSAppleEventDescriptor?
        switch self {
        case .windowIDs: built = ChromeAppleEvents.everyWindow().flatMap { ChromeAppleEvents.property("ID  ", of: $0) }
        case .mode(let w): built = ChromeAppleEvents.specifier(.window(w), property: "mode")
        case .activeTabID(let w): built = ChromeAppleEvents.specifier(.activeTab(w), property: "ID  ")
        case .tabURL(let w, let t): built = ChromeAppleEvents.specifier(.tab(w, t), property: "URL ")
        case .tabTitle(let w, let t): built = ChromeAppleEvents.specifier(.tab(w, t), property: "pnam")
        }
        return built.flatMap { ChromeAppleEvents.audit($0) ? $0 : nil }
    }
    /// Pure reply decoding. Anything unexpected is nil (skip).
    public func decode(_ d: NSAppleEventDescriptor) -> ChromePageReply? {
        switch self {
        case .windowIDs:
            if d.descriptorType == ChromeAppleEvents.code("list") {
                guard d.numberOfItems <= ChromePageProbe.maxWindows else { return nil }
                var ids: [String] = []
                for i in stride(from: 1, through: d.numberOfItems, by: 1) {
                    guard let id = d.atIndex(i)?.stringValue else { return nil }
                    ids.append(id)
                }
                return .ids(ids)
            }
            return d.stringValue.map { .ids([$0]) }
        case .mode, .activeTabID, .tabURL, .tabTitle:
            guard [ChromeAppleEvents.code("utxt"), ChromeAppleEvents.code("TEXT")].contains(d.descriptorType) else { return nil }
            return d.stringValue.map { .text($0) }
        }
    }
}
public enum ChromePageReply: Equatable, Sendable {
    case ids([String])
    case text(String)
}

/// One page as it may be saved: the window and tab it was in, the origin, and
/// the cleaned title ("" for chat pages, for email pages unless "Save email subjects" is on and the title passes
/// `EmailTitle.web`: email-1003, owner decision 2026-10-03; a search engine's results page's search words, `SearchPage`:
/// claude/search-1005, owner decision 2026-10-04; "" for any other search page).
public struct ChromePageRead: Equatable, Sendable {
    public let windowID: String
    public let tabID: String
    public let origin: String
    public let title: String
    public let siteOnly: Bool
    /// fix/show-all: the page's own link (`BrowserSites.pageLink`: page-links-1003 keeps a YouTube video's v, t and list
    /// and a plain section anchor, never another query part), kept on this Mac only for Open Original; nil for site-only
    /// pages and wherever no safe link can be kept. Never part of the dedupe key.
    public let link: String?
    /// fix/chrome-x2: a search results page's engine and query (`ChromePageProbe.read`'s `searchQuery`, owner build with
    /// typing and Search and AI on); nil otherwise. Saved only as a typed row (`WebTypedRow.searchEvidence`), never on the
    /// page row; not part of equality (the page row stays the site only, once).
    public var search: (engine: String, query: String)? = nil
    public init(windowID: String, tabID: String, origin: String, title: String, siteOnly: Bool, link: String? = nil) {
        self.windowID = windowID; self.tabID = tabID; self.origin = origin; self.title = title; self.siteOnly = siteOnly
        self.link = siteOnly ? nil : link
    }
    public static func == (a: ChromePageRead, b: ChromePageRead) -> Bool {
        a.windowID == b.windowID && a.tabID == b.tabID && a.origin == b.origin && a.title == b.title && a.siteOnly == b.siteOnly && a.link == b.link
    }
}
/// Why nothing was saved. None of these carries a site, a title or a mode.
public enum ChromePageSkip: String, Equatable, Sendable {
    /// Timeout, error, denial, odd reply or oversized answer.
    case unreadable
    case noWindows, tooManyWindows
    /// Some window is Incognito, Guest or not plainly "normal".
    case notNormal
    case invalidAddress
    /// Blocked site, blocked address or a title that looks private.
    case blocked
    /// Half-loaded or placeholder title.
    case unstableTitle
    /// The window list, a mode, the tab or the address changed during the read.
    case changed
}
public enum ChromePageResult: Equatable, Sendable {
    case page(ChromePageRead)
    case skipped(ChromePageSkip)
}

public enum ChromePageProbe {
    public static let maxWindows = 64
    public static let maxURLBytes = 8192
    public static let maxTitleBytes = 4096

    /// One full read. `ask` returns nil on a timeout, an error or a denial.
    /// The first failure returns at once and no later request is sent. The full
    /// address is used only to decide and to compare, then dropped.
    /// `emailSubjects`: "Save email subjects" (`PrivacySettings.emailSubjects`): an email page (`BrowserSites.emailPage`)
    /// keeps its cleaned title (`EmailTitle.web`) though it stays site-only (no link, no path). Off: the site only.
    /// `searchQuery` (fix/chrome-x2, owner build only): a search results page's engine and query from the same address,
    /// kept on the read (`ChromePageRead.search`) only when the whole read succeeds.
    public static func read(userBlocked: [String], emailSubjects: Bool = false, searchQuery: ((String) -> (engine: String, query: String)?)? = nil,
                            _ ask: (ChromePageRequest) -> ChromePageReply?) -> ChromePageResult {
        // 1. Window list.
        guard case .ids(let ids)? = ask(.windowIDs), ids.allSatisfy(ChromeAppleEvents.validID),
              Set(ids).count == ids.count else { return .skipped(.unreadable) }
        guard !ids.isEmpty else { return .skipped(.noWindows) }
        guard ids.count <= maxWindows else { return .skipped(.tooManyWindows) }
        // 2. Every window's mode, before anything about any page.
        if let skip = modes(ids, ask) { return .skipped(skip) }
        // 3. Active tab of the front window (Chrome lists windows front to back).
        let front = ids[0]
        guard case .text(let tab)? = ask(.activeTabID(front)), ChromeAppleEvents.validID(tab) else { return .skipped(.unreadable) }
        // 4. Address, judged and dropped.
        guard case .text(let url)? = ask(.tabURL(front, tab)), url.utf8.count <= maxURLBytes else { return .skipped(.unreadable) }
        let origin: String, siteOnly: Bool
        switch BrowserSites.pageDecision(url, userBlocked: userBlocked) {
        case .invalid: return .skipped(.invalidAddress)
        case .blocked: return .skipped(.blocked)
        case .siteOnly(let o): origin = o; siteOnly = true
        case .record(let o): origin = o; siteOnly = false
        }
        // 5. Title, only when one may be kept: a page that keeps its title, or (email-1003, owner decision 2026-10-03)
        // an email page while "Save email subjects" is on: its folder or open email's subject (`EmailTitle.web`),
        // cleaned and scrubbed; nothing usable keeps the site only. An email page stays site-only (no link, no path).
        // claude/search-1005 (owner decision 2026-10-04): a search engine's results page keeps its search words as the
        // title (`SearchPage.query`, from the address already read); only when the address has none is the tab title
        // asked for ("<words> - Google Search", `SearchPage.titleQuery`). Words that can't be kept leave the site only.
        // A search page stays site-only (no link, no path, no other part of the address).
        var title = ""
        let emailTitle = siteOnly && emailSubjects && BrowserSites.emailPage(url)
        let searchPage = siteOnly && !emailTitle && SearchPage.resultsPage(url)
        let searchWords = searchPage ? SearchPage.query(url)?.query : nil
        if let searchWords { title = searchWords }
        if !siteOnly || emailTitle || (searchPage && searchWords == nil) {
            guard case .text(let raw)? = ask(.tabTitle(front, tab)), raw.utf8.count <= maxTitleBytes else { return .skipped(.unreadable) }
            if searchPage {
                title = SearchPage.titleQuery(raw, url: url)?.query ?? ""
            } else if emailTitle {
                guard !ObservationPolicy.titleLooksPrivate(raw) else { return .skipped(.blocked) }
                if let kept = EmailTitle.web(raw, host: BrowserSites.host(of: origin) ?? "").flatMap({ ChromePageTitle.clean($0, origin: origin, url: url) }),
                   !ObservationPolicy.titleLooksPrivate(kept) { title = kept }
            } else {
                guard let cleaned = ChromePageTitle.clean(raw, origin: origin, url: url) else { return .skipped(.unstableTitle) }
                guard !ObservationPolicy.titleLooksPrivate(cleaned) else { return .skipped(.blocked) }
                title = cleaned
            }
        }
        // 6. Re-check: same windows, all still normal, same tab, same address.
        // A reply that differs is a change; no reply at all is unreadable.
        guard let again = ask(.windowIDs) else { return .skipped(.unreadable) }
        guard again == .ids(ids) else { return .skipped(.changed) }
        if let skip = modes(ids, ask) { return .skipped(skip) }
        guard let tabAgain = ask(.activeTabID(front)) else { return .skipped(.unreadable) }
        guard tabAgain == .text(tab) else { return .skipped(.changed) }
        guard let urlAgain = ask(.tabURL(front, tab)) else { return .skipped(.unreadable) }
        guard urlAgain == .text(url) else { return .skipped(.changed) }
        // 7. Only the origin, the cleaned title and (fix/show-all, kept on this Mac only for Open Original) the page's safe
        // link (page-links-1003: `BrowserSites.pageLink`, allow-listed query keys only) leave this function, plus
        // (fix/chrome-x2, owner build only) a results page's engine and query when `searchQuery` is given.
        var read = ChromePageRead(windowID: front, tabID: tab, origin: origin, title: title, siteOnly: siteOnly,
                                  link: siteOnly ? nil : BrowserSites.pageLink(url))
        read.search = searchQuery?(url)
        return .page(read)
    }
    /// nil when every window answers exactly "normal".
    private static func modes(_ ids: [String], _ ask: (ChromePageRequest) -> ChromePageReply?) -> ChromePageSkip? {
        for id in ids {
            guard let reply = ask(.mode(id)) else { return .unreadable }
            guard reply == .text("normal") else { return .notNormal }
        }
        return nil
    }
}

public enum ChromePageTitle {
    public static let limit = 160
    static let placeholders: Set<String> = ["new tab", "untitled", "loading…", "loading...", "about:blank"]
    /// nil for empty, placeholder, half-loaded (the address as title) and
    /// otherwise unusable titles. Strips one unread counter "(3) " and one
    /// leading dot, then cleans and cuts to 160 characters.
    /// `url` is the full address, used here only to spot a title that is the
    /// address itself; it is never kept.
    public static func clean(_ raw: String, origin: String, url: String? = nil) -> String? {
        var t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = t.lowercased()
        guard !t.isEmpty, t != origin, t != BrowserSites.host(of: origin),
              !lower.hasPrefix("http://"), !lower.hasPrefix("https://"),
              !placeholders.contains(lower), !isAddress(t, origin: origin, url: url) else { return nil }
        if let r = t.range(of: #"^\(\d{1,4}\+?\)\s*"#, options: .regularExpression) { t.removeSubrange(r) }
        if let r = t.range(of: #"^[•●]\s*"#, options: .regularExpression) { t.removeSubrange(r) }
        let cleaned = Privacy.clean(t, limit: limit)
        return cleaned.isEmpty ? nil : cleaned
    }
}

extension ChromePageTitle {
    /// A page with no title of its own: Chrome shows its address as the tab
    /// title, dropping "http://" (and often "www."): "intranet.corp/hr?id=4",
    /// "localhost:3000/api", "192.168.1.20:8080". Saving that would save the
    /// path and query, so any title that starts with the site followed by
    /// "/", "?", "#" or ":<port>" is refused, and so is a file name taken from
    /// the address ("report-4411.pdf").
    static func isAddress(_ title: String, origin: String, url: String?) -> Bool {
        var t = title.lowercased()
        for scheme in ["http://", "https://"] where t.hasPrefix(scheme) { t.removeFirst(scheme.count) }
        if t.hasPrefix("www.") { t.removeFirst(4) }
        guard let site = BrowserSites.parts(origin) else { return true }
        var host = site.host
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let sites = [host] + (site.port.map { ["\(host):\($0)"] } ?? [])
        for name in sites {
            if t == name || t == name + "/" { return true }
            guard t.hasPrefix(name) else { continue }
            let rest = t.dropFirst(name.count)
            if let next = rest.first, "/?#".contains(next) { return true }
            if rest.first == ":", let digit = rest.dropFirst().first, digit.isNumber { return true }
        }
        guard let url, let address = URLComponents(string: url) else { return false }
        var bare = url.lowercased()
        for scheme in ["http://", "https://"] where bare.hasPrefix(scheme) { bare.removeFirst(scheme.count) }
        if t == bare || (bare.hasPrefix("www.") && t == String(bare.dropFirst(4))) { return true }
        // A file shown by name ("scan 2291.pdf"): the last part of the path.
        if let last = address.path.split(separator: "/").last.map(String.init), last.contains("."),
           title.trimmingCharacters(in: .whitespacesAndNewlines) == last { return true }
        return false
    }
}

/// Dedup key: window, tab, origin and title ("" for site-only pages, an email page's kept title: email-1003).
public struct ChromePageKey: Hashable, Sendable {
    public let value: String
    /// Window and tab only: the same tab whatever page it shows.
    let tab: String
    public init(_ read: ChromePageRead) {
        value = [read.windowID, read.tabID, read.origin, read.title].joined(separator: "|")
        tab = read.windowID + "|" + read.tabID
    }
}

public enum ChromePageStep: Equatable {
    case record(ChromePageRead)
    case confirm(after: TimeInterval)
    case nothing
}

/// Dwell, dedup and flicker. A page is saved only after two full reads at
/// least a second apart agree on it; the same page is never saved twice in a
/// row, and a tab whose title keeps flipping between the same few titles
/// (a play button, a notification flash) is saved once per title, not once
/// per flip.
public struct ChromePageTracker {
    public static let minDwell: TimeInterval = 1.0, confirmDelay: TimeInterval = 1.2, maxChain = 5
    /// A title in the same tab seen again within this long is flicker.
    public static let flickerWindow: TimeInterval = 10
    public private(set) var lastRecorded: ChromePageKey?
    public private(set) var chain = 0
    private var candidate: (key: ChromePageKey, at: Date)?
    /// Pages saved (or passed over as flicker) lately, with when they were last seen.
    private var recent: [ChromePageKey: Date] = [:]
    /// What `lastRecorded` was before the last `.record`, in case the write is refused.
    private var beforeRecord: ChromePageKey?
    /// Refused writes of the same page in a row: after `maxRefused` only the poll retries.
    private var refused: (key: ChromePageKey, count: Int)?
    public static let maxRefused = 3
    public var hasCandidate: Bool { candidate != nil }
    public init() {}

    public mutating func observe(_ read: ChromePageRead, at: Date) -> ChromePageStep {
        let key = ChromePageKey(read)
        if key == lastRecorded { candidate = nil; recent[key] = at; return .nothing }
        // Flicker: the same tab went back to a page saved moments ago.
        if let seen = recent[key], at.timeIntervalSince(seen) >= 0, at.timeIntervalSince(seen) <= Self.flickerWindow,
           let last = lastRecorded, last.tab == key.tab {
            candidate = nil; lastRecorded = key; recent[key] = at
            return .nothing
        }
        if let c = candidate, c.key == key {
            let elapsed = at.timeIntervalSince(c.at)
            if elapsed >= Self.minDwell {
                beforeRecord = lastRecorded
                lastRecorded = key; candidate = nil; chain = 0
                if let last = beforeRecord, last.tab != key.tab { recent.removeAll() }
                recent = recent.filter { at.timeIntervalSince($0.value) <= Self.flickerWindow }
                recent[key] = at
                return .record(read)
            }
            return .confirm(after: max(0.2, Self.confirmDelay - elapsed))
        }
        candidate = (key, at); chain += 1
        return chain > Self.maxChain ? .nothing : .confirm(after: Self.confirmDelay)
    }
    /// The last `.record` was refused at write (late, switch off, policy
    /// changed): it does not count as saved, so the page is read again.
    public mutating func notSaved(_ read: ChromePageRead, at: Date) -> ChromePageStep {
        let key = ChromePageKey(read)
        guard lastRecorded == key else { return .nothing }
        lastRecorded = beforeRecord; beforeRecord = nil
        recent[key] = nil
        // Both reads already agreed: one more read that agrees saves it.
        candidate = (key, at)
        let count = (refused?.key == key ? refused!.count : 0) + 1
        refused = (key, count)
        return count > Self.maxRefused ? .nothing : .confirm(after: Self.confirmDelay)
    }
    /// A half-loaded title or a change during the read: look again soon.
    public mutating func unstable(at: Date) -> ChromePageStep {
        candidate = nil; chain += 1
        return chain > Self.maxChain ? .nothing : .confirm(after: Self.confirmDelay)
    }
    /// Incognito/Guest, blocked, invalid or no window: forget the last page, so
    /// the same page coming back afterwards is saved again.
    public mutating func skipped() { candidate = nil; lastRecorded = nil; recent.removeAll(); refused = nil }
    public mutating func reset() { candidate = nil; lastRecorded = nil; chain = 0; recent.removeAll(); beforeRecord = nil; refused = nil }
}
