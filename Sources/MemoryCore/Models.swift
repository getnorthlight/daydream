import Foundation
import CryptoKit
import HistoryCore
import PrivacyPolicy

public enum MemError: Error, CustomStringConvertible {
    case invalid(String), database(String), denied, missing
    /// Another connection held the database (SQLITE_BUSY or SQLITE_LOCKED) past the busy timeout. Nothing was
    /// written; the same write can succeed a moment later.
    case busy(String)
    public var description: String {
        switch self {
        case .invalid(let s): return s
        case .database(let s): return "Memory storage error: \(s)"
        case .busy(let s): return "Memory storage busy: \(s)"
        case .denied: return "Client grant missing, revoked, or outside its scope."
        case .missing: return "No memory yet. Open DayDream or use an isolated --demo directory."
        }
    }
    /// The SQLite result code a storage error carries (MemoryStore writes it as "… (code N)"); nil for any other error.
    public var sqliteCode: Int32? {
        let text: String
        switch self {
        case .database(let s), .busy(let s): text = s
        default: return nil
        }
        guard let open = text.range(of: "(code ", options: .backwards),
              let close = text[open.upperBound...].firstIndex(of: ")") else { return nil }
        return Int32(text[open.upperBound..<close])
    }
}

/// Lowercase hex SHA-256. Hex by table, not `String(format:)` per byte: this runs several times for every action a
/// day assembly reads, and the formatter was about a third of a cold day read.
public func fingerprint(_ text: String) -> String {
    var hex = [UInt8](); hex.reserveCapacity(64)
    for byte in SHA256.hash(data: Data(text.utf8)) {
        hex.append(hexDigits[Int(byte >> 4)]); hex.append(hexDigits[Int(byte & 0x0f)])
    }
    return String(decoding: hex, as: UTF8.self)
}
private let hexDigits = Array("0123456789abcdef".utf8)
/// Shared formatters and a direct read of DayDream's own two forms (ISOTimestamp.swift): these run for every action on hot paths.
public func iso(_ date: Date) -> String { ISOTimestamp.string(date) }
/// Fractional seconds: `iso` has one-second resolution, too coarse for a
/// freshness window of about a second.
public func isoPrecise(_ date: Date) -> String { ISOTimestamp.preciseString(date) }
public func timestamp(_ text: String) -> Date? { ISOTimestamp.date(text) }
public func json<T: Encodable>(_ value: T) throws -> String {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(value), as: UTF8.self)
}
public func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T {
    try JSONDecoder().decode(type, from: Data(value.utf8))
}
public enum MemPaths {
    public static func home() -> URL {
        if let value = ProcessInfo.processInfo.environment["MAC_MEM_HOME"], !value.isEmpty {
            return URL(fileURLWithPath: value, isDirectory: true)
        }
        return resolvedHome(applicationSupport: FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true))
    }
    /// The DayDream folder, unless only the old Mac Mem folder holds a history (an older
    /// install whose one-time move hasn't happened yet): then the old folder, so the app,
    /// the command-line tool and AI apps always read the same history.
    public static func resolvedHome(applicationSupport: URL) -> URL {
        let current = applicationSupport.appendingPathComponent(DaydreamIdentity.dataFolder, isDirectory: true)
        let legacy = applicationSupport.appendingPathComponent(DaydreamIdentity.legacyDataFolder, isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: current.appendingPathComponent("memory.sqlite").path) { return current }
        if fm.fileExists(atPath: legacy.appendingPathComponent("memory.sqlite").path) { return legacy }
        return current
    }
}

public struct Evidence: Codable, Equatable {
    public var id: String
    public var at: String
    public var kind: String
    public var app: String
    public var bundle: String
    public var title: String
    public var url: String
    public var text: String
    public var secure: Bool
    public var privateWindow: Bool
    public var synthetic: Bool
    public var browserVerification: BrowserVerification?
    public var sendVerification: SendVerification?
    public var captureProvenance:NativeCaptureProvenance? = nil
    /// Typed rows only: where the sealed words are (`typed_text`), never the
    /// words. Optional so every earlier row decodes and hashes unchanged.
    public var typed:TypedRef? = nil
    /// fix/show-all: a Chrome page's own link (scheme, host and path; page-links-1003: a YouTube video's v, t and list and a
    /// plain section anchor, never another query part, a token or a login: `BrowserSites.pageLink`), kept on this Mac
    /// only so Open Original opens that page, not just its site. `url` stays the origin, so every earlier row, every
    /// dedupe key and every reply that names a site is unchanged; no MCP or CLI reply, search document, writer or cloud
    /// request reads this field (`readerItem` drops it). nil for every other row. Optional so earlier rows decode and
    /// hash unchanged.
    public var page:String? = nil
    /// claude/int-1003: the AI coding tool a terminal window's title named only by its status glyph ("✳ <topic>" is Claude
    /// Code, `TitleClean.terminalTool`), kept when `Privacy.sanitized` drops the glyph (title-spinner-1003); "" for a busy
    /// spinner that names no tool ("◐ <topic>"). Metadata, never typed words. nil for every other row; optional so earlier
    /// rows decode and hash unchanged.
    public var titleTool:String? = nil
    public init(id: String, at: String, kind: String, app: String, bundle: String = "", title: String = "", url: String = "", text: String = "", secure: Bool = false, privateWindow: Bool = false, synthetic: Bool = false, browserVerification: BrowserVerification? = nil, sendVerification: SendVerification? = nil) {
        self.id = id; self.at = at; self.kind = kind; self.app = app; self.bundle = bundle
        self.title = title; self.url = url; self.text = text; self.secure = secure
        self.privateWindow = privateWindow; self.synthetic = synthetic
        self.browserVerification = browserVerification
        self.sendVerification = sendVerification
    }
}
/// Collection provenance, not a reusable permission or proof of sending.
public struct NativeCaptureProvenance:Codable,Equatable {
    public var policyRevision:String, classifierVersion:String, windowID:String, focusID:String, checkedAt:String
    public var generation:UInt64
    /// Typed-unit metadata. Optional so rows written before typed units decode.
    public var unit:TypedUnitProvenance?=nil
    public init(policyRevision:String,classifierVersion:String,windowID:String,focusID:String,checkedAt:String,generation:UInt64,unit:TypedUnitProvenance?=nil) {
        self.policyRevision=policyRevision;self.classifierVersion=classifierVersion;self.windowID=windowID
        self.focusID=focusID;self.checkedAt=checkedAt;self.generation=generation;self.unit=unit
    }
}
/// How one keyboard.text_input row was cut from typing. Rows of one run
/// (split by idle or size) share runID; part counts from 1. Metadata only:
/// counts and reasons, never text. `keys` and `edits` are nil when anything
/// was withheld: with the stored text they would give the withheld length.
public struct TypedUnitProvenance:Codable,Equatable {
    /// "typed-unit/v3" for rows sealed with the send facts below; older rows keep "typed-unit/v2" and decode them as nil
    /// (synthesized Codable writes nil optionals with encodeIfPresent, so an old row's JSON and revision never change).
    public var version="typed-unit/v2"
    public static let sendFactsVersion="typed-unit/v3"
    public var runID:String, part:Int, sealReason:String, startedAt:String
    public var keys:Int?, edits:Int?, withheld:Int
    /// summaries/v3 (spec §2): code-decided facts at seal time. Metadata only, never words.
    /// surface: ai | aiTool | email | text | chat | social | search | form | code | writing | other
    public var surface:String?=nil
    /// field: to | subject | body | message | search | oneLine | textArea | unknown
    public var field:String?=nil
    /// send: detected | none | unknown. Never "sent": that stays receipt-only (SendVerification).
    public var send:String?=nil
    /// sendBy: return | commandReturn | mailSend | button. "button" (fix/chrome-capture) is a click DayDream proved on the
    /// composer's own submit control after the words were saved (`SendRules.buttonSend`); it is a send gesture, never a
    /// delivery.
    public var sendBy:String?=nil
    /// A recipient or place code read (a parsed window title or composer label), never taken from the typed words.
    public var to:String?=nil
    /// A paste seal or Command-V happened inside this run.
    public var pasted:Bool?=nil
    /// fix/chrome-capture: with sendBy "button", which control it was, from a fixed list ("post" | "reply" | "post all":
    /// `BrowserSubmitControls`). Absent on every other row, so their JSON and revisions never change.
    public var sendControl:String?=nil
    /// compose-send/v1 (`ComposeSend`): what confirmed a send ("fieldCleared" | "composerClosed" | "routeChanged"), and the
    /// identity adapter's destination and reply context (`ComposeIdentity`): a handle (no "@"), a community ("swift" for
    /// r/swift), an email subject, and the parent post's author and excerpt (at most `ComposeSend.contextLimit`
    /// characters, from the page title or Accessibility at the gesture; never the typed words). All absent on earlier
    /// rows, whose JSON and revisions never change.
    public var confirm:String?=nil
    public var handle:String?=nil
    public var community:String?=nil
    public var subject:String?=nil
    public var contextAuthor:String?=nil
    public var contextExcerpt:String?=nil
    public init(runID:String,part:Int,sealReason:String,startedAt:String,keys:Int?,edits:Int?,withheld:Int,
                surface:String?=nil,field:String?=nil,send:String?=nil,sendBy:String?=nil,to:String?=nil,pasted:Bool?=nil) {
        self.runID=runID;self.part=part;self.sealReason=sealReason;self.startedAt=startedAt
        self.keys=keys;self.edits=edits;self.withheld=withheld
        self.surface=surface;self.field=field;self.send=send;self.sendBy=sendBy;self.to=to;self.pasted=pasted
        if surface != nil || send != nil { version=Self.sendFactsVersion }
    }
}
public struct MemoryItem: Codable, Equatable {
    public var id: String
    public var evidence: Evidence
    public var summary: String
    public var actionState: String
    public var inference: Bool
    public var generatedAt: String
    public var coverageThrough: String
    public var revision: String
    public var writer: String
    public var correction:UserCorrection? = nil
}
public struct PrivacySettings: Codable, Equatable {
    public var blockedApps: [String] = []
    public var blockedDomains: [String] = []
    public var retention: MemoryRetention = .never
    /// Compatibility source accessor: nil means Never. Zero is always invalid.
    /// UI must bind retention, never coalesce this to 30 or 0.
    public var retentionDays: Int? {
        get {if case .days(let n)=retention{return n};return nil}
        set {retention=newValue.map(MemoryRetention.days) ?? .never}
    }
    public var captureText: Bool = false
    // Older builds defaulted captureText to true without explicit typed-only
    // consent. They cannot authorize new keyboard capture after this upgrade.
    public var typedConsentVersion: Int? = nil
    /// The typed-text switch as it behaves: on only with this build's typed-text consent. Compare this,
    /// never the raw `captureText`, with what a screen shows.
    public var typingOn: Bool { captureText && typedConsentVersion == 1 }
    /// "Web pages in Chrome". Off in a new store; a first setup shows its switch on (opt-out) and saves the choice. Counts only with this build's consent version
    /// (`browserPagesConsentCurrent`, the Settings disclosure text); a material text change bumps it.
    /// Always off in a release built with `ReleaseFeatures.chromePageHistory` false.
    public var browserPages: Bool = false
    public var browserPagesConsentVersion: Int? = nil
    public var browserPagesOn: Bool { ReleaseFeatures.chromePageHistory && browserPages && browserPagesConsentVersion == Self.browserPagesConsentCurrent }
    /// The "Web pages in Chrome" text this build shows (`ChromePagesCard.explanation`): version 1 in public
    /// builds. The owner build (`OwnerTyping`) records website typing, so its text says so and is version 2:
    /// a consent given to one text never counts for the other.
    public static var browserPagesConsentCurrent: Int { OwnerTyping.enabled ? 2 : 1 }
    /// "Save email subjects" (Settings › Web pages in Chrome; email-1003, owner decision 2026-10-03: default on). On: an
    /// email page row keeps its cleaned title (`EmailTitle`). Off: the site only, at capture and at read
    /// (`Privacy.sanitized`). Stored only when off, so a policy saved before this field reads as on.
    public var emailSubjects: Bool = true
    public var revision: String = UUID().uuidString
    /// What generated notes bind to in place of `revision` (gold/notes G21). A save keeps it unless the save can change
    /// what an earlier writer read without changing the actions themselves (typing turned off), so an unrelated
    /// save no longer hides every note. nil (a policy from before this field): `revision` binds, as it always did.
    public var notesRevision: String? = nil
    public var notesBinding: String { notesRevision ?? revision }
    /// Seconds since 1970 from which an action may continue the moment before it (sat5 continuation, gold/notes G22).
    /// A new store: 0. A store from before the rule gets the time of its first writable open, so the days it
    /// already has keep their moments and notes. nil: not stamped yet; no action continues.
    public var continuationSince: Double? = 0
    public init() {}
    private enum Keys: String, CodingKey {case blockedApps,blockedDomains,retention,retentionDays,captureText,typedConsentVersion,browserPages,browserPagesConsentVersion,emailSubjects,revision,notesRevision,continuationSince}
    public init(from decoder: Decoder) throws {
        let c=try decoder.container(keyedBy:Keys.self)
        blockedApps=try c.decode([String].self,forKey:.blockedApps)
        blockedDomains=try c.decode([String].self,forKey:.blockedDomains)
        captureText=try c.decode(Bool.self,forKey:.captureText)
        typedConsentVersion=try c.decodeIfPresent(Int.self,forKey:.typedConsentVersion)
        browserPages=try c.decodeIfPresent(Bool.self,forKey:.browserPages) ?? false
        browserPagesConsentVersion=try c.decodeIfPresent(Int.self,forKey:.browserPagesConsentVersion)
        emailSubjects=try c.decodeIfPresent(Bool.self,forKey:.emailSubjects) ?? true
        revision=try c.decode(String.self,forKey:.revision)
        notesRevision=try c.decodeIfPresent(String.self,forKey:.notesRevision)
        continuationSince=try c.decodeIfPresent(Double.self,forKey:.continuationSince)
        if c.contains(.retention) {
            retention=try c.decode(MemoryRetention.self,forKey:.retention)
            if c.contains(.retentionDays) {
                guard retention == .days(try c.decode(Int.self,forKey:.retentionDays)) else {throw MemError.invalid("Conflicting retention fields")}
            }
        } else {
            // Existing explicit numeric policies stay finite. Missing/null/
            // malformed policy does NOT become a new-profile Never default.
            retention = .days(try c.decode(Int.self,forKey:.retentionDays))
        }
        try retention.validate()
    }
    public func encode(to encoder: Encoder) throws {
        try retention.validate();var c=encoder.container(keyedBy:Keys.self)
        try c.encode(blockedApps,forKey:.blockedApps);try c.encode(blockedDomains,forKey:.blockedDomains)
        try c.encode(captureText,forKey:.captureText);try c.encodeIfPresent(typedConsentVersion,forKey:.typedConsentVersion)
        try c.encode(browserPages,forKey:.browserPages);try c.encodeIfPresent(browserPagesConsentVersion,forKey:.browserPagesConsentVersion)
        if !emailSubjects {try c.encode(false,forKey:.emailSubjects)}
        try c.encode(revision,forKey:.revision);try c.encode(retention,forKey:.retention)
        try c.encodeIfPresent(notesRevision,forKey:.notesRevision);try c.encodeIfPresent(continuationSince,forKey:.continuationSince)
        // Old binaries can still read finite policies. They reject Never due to
        // a missing mandatory day field rather than silently expiring at 30d.
        if let days=retentionDays {try c.encode(days,forKey:.retentionDays)}
    }
    public var policy: ObservationPolicy {
        var rules = (Self.sensitiveApps + SystemProcesses.bundleIDs.sorted() + blockedApps).map { ObservationPolicy.Rule(scope: .application, bundleID: $0) }
        rules += (Self.sensitiveDomains + blockedDomains).map { ObservationPolicy.Rule(scope: .url, urlDomain: $0) }
        return ObservationPolicy(blocklist: rules)
    }
    /// DayDream itself, then the common password managers (`PasswordManagerApps`, PreCapturePrivacy.swift).
    public static let sensitiveApps = [DaydreamIdentity.bundleID, DaydreamIdentity.legacyBundleID] + PasswordManagerApps.bundleIDs
    public static let sensitiveDomains = ["1password.com", "bitwarden.com", "passwords.google.com", "chase.com", "bankofamerica.com", "wellsfargo.com", "citi.com", "fidelity.com", "schwab.com", "paypal.com", "venmo.com"]
}

/// macOS's own alert, prompt and system-UI processes (live test, build 7: "UserNotificationCenter ~4 min" was the
/// day's headline). They are never an activity: nothing is recorded from them, and rows already saved are not shown
/// (the privacy policy's app rules drop them at capture and at read, like DayDream itself). Not a setting and not
/// listed as an excluded app. The capture side also skips any frontmost process that isn't a regular app
/// (`regularApp` false: LSUIElement agents and background-only helpers, Apple's or anyone's) for activity rows;
/// typing has its own proof and allowlist and is not affected.
public enum SystemProcesses {
    public static let bundleIDs: Set<String> = [
        // Alerts, permission and password prompts.
        "com.apple.UserNotificationCenter",            // "X would like to…" alerts, the TCC prompts
        "com.apple.SecurityAgent",                     // admin password dialogs
        "com.apple.LocalAuthentication.UIAgent",       // coreautha: Touch ID / password sheets
        "com.apple.coreservices.uiagent",              // CoreServicesUIAgent: "downloaded from the Internet" alerts
        "com.apple.CoreServicesUIAgent",
        "com.apple.accessibility.universalAccessAuthWarn", // "X would like to control this computer" (Accessibility)
        "com.apple.security.Keychain-Circle-Notification",
        "com.apple.CoreLocationAgent",
        "com.apple.loginwindow",                        // the lock screen and login window
        // System UI that can take focus for a moment.
        "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui", "com.apple.WindowManager",
        "com.apple.systemuiserver", "com.apple.OSDUIHelper", "com.apple.screencaptureui", "com.apple.ScreenSaver.Engine",
        "com.apple.AirPlayUIAgent", "com.apple.wifi.WiFiAgent", "com.apple.TextInputMenuAgent",
    ]
    /// Whether a frontmost process is system noise, not an activity. `regularApp`: its activation policy is
    /// `.regular` (a Dock app); nil when unknown (stored rows: judged by bundle ID alone).
    public static func excluded(bundle: String, regularApp: Bool?) -> Bool {
        bundleIDs.contains(bundle) || regularApp == false
    }
}

public enum Privacy {
    public static func clean(_ value: String, limit: Int = 2000) -> String {
        let scalars = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) || $0 == "\n" || $0 == "\t" }
        return String(String.UnicodeScalarView(scalars)).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").prefixString(limit)
    }
    /// What `secret` looks for. claude/perf2-1003: `String.range(of:options:.regularExpression)` compiles its pattern on
    /// every call, up to ten of them per `secret` (~35-65 µs a call), and every record read calls `secret` several times
    /// (`sanitized`: the title, the text, the URL's path and query): a day's assembly, a search page, an index page, the
    /// in-app typed pass (once per word). The answers stay exactly the String API's (it rejects some matches the plain
    /// expression finds: a `$` before a final newline, a match inside a letter with a combining mark), so:
    /// - in a value whose every character is one Unicode scalar (nearly all), each pattern is first tried compiled once
    ///   (`secretExpressions`). There it finds every match the String API finds and more, so no match is a sure no; a
    ///   match is confirmed with the String API itself (rare: a secret). Any other value goes to the String API as before;
    /// - the four character classes are read from the bytes of an ASCII value without a carriage return (one character
    ///   per byte, as the String API reads it), else with the String API as before.
    /// `scripts/perf-1003-checks.swift` (F) holds the answers to the previous implementation's on fixed and fuzzed text.
    static let secretPatterns = [
        "(?i)(password|passwd|pwd|secret|token|api[_-]?key)\\s*[:=]",
        "(?i)(sk-|sk_live_|ghp_|github_pat_|xox[bap]-|AKIA|AIza|Bearer\\s+)[A-Za-z0-9_./+-]{6,}",
        "-----BEGIN [A-Z ]*(PRIVATE KEY|CERTIFICATE)",
        "eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.",
        "(?<![0-9])(?:[0-9][ -]?){13,19}(?![0-9])",
        "^\\d{4,8}$",
    ]
    static let secretClassPatterns = ["[a-z]", "[A-Z]", "[0-9]", "[^A-Za-z0-9]"]
    /// The patterns compiled once, with no options (an NSRegularExpression is immutable and safe from any thread).
    private static let secretExpressions = secretPatterns.map { try! NSRegularExpression(pattern: $0) }
    public static func secret(_ value: String) -> Bool {
        if value.unicodeScalars.count == value.count {
            let whole = NSRange(value.startIndex..., in: value)
            for (i, expression) in secretExpressions.enumerated() where expression.firstMatch(in: value, range: whole) != nil {
                if value.range(of: secretPatterns[i], options: .regularExpression) != nil { return true }
            }
        } else if secretPatterns.contains(where: { value.range(of: $0, options: .regularExpression) != nil }) {
            // A character of several scalars (a combining mark, a flag, CR LF): the String API reads it as one character
            // ("4" with an accent is a digit there), so the compiled expressions can't rule a match out.
            return true
        }
        let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !ContactShape.email(v), !ContactShape.phone(v), !v.contains(" "), (8...80).contains(v.count), !v.contains("://") {
            if secretClasses(v) >= 3 { return true }
        }
        return false
    }
    /// How many of `secretClassPatterns` occur in `v`.
    static func secretClasses(_ v: String) -> Int {
        guard v.utf8.allSatisfy({ $0 < 0x80 && $0 != 0x0D }) else {
            return secretClassPatterns.filter { v.range(of: $0, options: .regularExpression) != nil }.count
        }
        var lower = false, upper = false, digit = false, other = false
        for b in v.utf8 {
            switch b {
            case 0x61...0x7A: lower = true
            case 0x41...0x5A: upper = true
            case 0x30...0x39: digit = true
            default: other = true
            }
        }
        return [lower, upper, digit, other].filter { $0 }.count
    }
    /// `presenting` (claude/title-spinner-1003): a title loses the status glyphs an app animates at its ends (every save and
    /// every read). A backup's "the policy leaves this record as it is" test passes false, so a row an earlier build saved
    /// with its glyph is still backed up byte for byte.
    public static func sanitized(_ original: Evidence, settings: PrivacySettings, now: Date = Date(), presenting: Bool = true) -> Evidence? {
        if !original.synthetic, CaptureSession.excludedBrowsers.contains(original.bundle), !BrowserSafety.valid(original) { return nil }
        guard !original.id.isEmpty, original.id.count <= 200, let time = timestamp(original.at), time <= now.addingTimeInterval(30),
              settings.retention.permits(time,now:now), !original.secure, !original.privateWindow,
              settings.policy.dropReason(bundleIdentifier: original.bundle, windowTitle: original.title, urlDomain: original.url) == nil,
              !PreCapturePrivacy.websiteDenied(original.url,settings:settings) else { return nil }
        var e = EmailTitle.scrubbed(original)
        // email-1003: "Save email subjects" off keeps an email page row to its site, whenever it was saved.
        if !settings.emailSubjects, e.browserVerification?.provider == BrowserSafety.pageProvider,
           let host = BrowserSites.host(of: e.url), BrowserSites.emailHost(host: host) { e.title = "" }
        // claude/title-spinner-1003 (audit B1/S4): a save stores, and every read (actions, moments, `read`, search, AI apps)
        // sees, a title without the status glyphs an app animates at its ends ("◐ Session" is "Session"), rows an earlier
        // build saved with the glyph included. The stored record itself is never rewritten.
        let glyphed = e.title
        e.title = secret(e.title) ? "[sensitive title omitted]" : clean(presenting ? TitleClean.statusless(e.title) : e.title, limit: 160)
        // claude/int-1003: the glyph named the AI tool (terminal-details' "Asked Claude Code", summary-1003's prompts to it);
        // the tool stays as a fact once the glyph is gone, so dropping it never turns a prompt into "Ran a command".
        if presenting, e.titleTool == nil, TitleClean.terminalApps.contains(e.app.lowercased()), !secret(glyphed),
           TitleClean.statusless(glyphed) != glyphed {
            if let tool = TitleClean.terminalTool(glyphed), TitleClean.terminalTool(e.title) == nil { e.titleTool = tool }
            else if glyphed.unicodeScalars.first.map({ TitleClean.spinnerGlyphs.contains($0.value) }) == true { e.titleTool = "" }
        }
        e.app = clean(e.app, limit: 80)
        e.text = settings.captureText && !secret(e.text) ? clean(e.text) : ""
        if var url = URLComponents(string: e.url), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil {
            // Only search queries survive, never auth tokens, fragments or arbitrary parameters.
            url.percentEncodedQueryItems = url.percentEncodedQueryItems?.filter {
                ["q", "query", "search_query"].contains($0.name) && !secret(searchValue($0.value ?? ""))
            }
            if url.percentEncodedQueryItems?.isEmpty == true { url.percentEncodedQueryItems = nil }
            url.fragment = nil
            e.url = secret(url.path) ? "" : clean(url.string ?? "", limit: 600)
        } else { e.url = "" }
        // fix/chrome-root (coordinator decision 10-02): a page row stored as its origin plus "/" by an earlier build
        // (BrowserSafety.page accepts exactly that) is shown as the bare origin.
        if e.browserVerification?.provider == BrowserSafety.pageProvider, let origin = BrowserSites.origin(e.url), e.url == origin + "/" { e.url = origin }
        // fix/show-all: a page link stays only while it is a safe link on the row's own site that passes every check
        // the site does (BrowserSites.pageLink: allow-listed query keys only, no login, token-like or blocked path, no
        // search, email or chat site).
        if let page = e.page {
            let site = URLComponents(string: e.url)?.host?.lowercased()
            e.page = BrowserSites.pageLink(page).flatMap { link in
                URLComponents(string: link)?.host?.lowercased() == site && site != nil && !PreCapturePrivacy.websiteDenied(link, settings: settings) ? link : nil
            }
        }
        return e
    }
    public static func searchValue(_ encoded:String) -> String {
        encoded.replacingOccurrences(of:"+",with:" ").removingPercentEncoding ?? ""
    }
}
extension String { public func prefixString(_ n: Int) -> String { String(prefix(max(0, n))) } }

public enum IntentWriter {
    public static func write(_ evidence: Evidence, now: Date = Date()) -> MemoryItem {
        let text = evidence.text
        let lower = text.lowercased()
        var summary: String
        var state = "observed"
        let recordedActions=["mouse.click":"a mouse click","mouse.context_menu":"a context-menu action","keyboard.shortcut":"a keyboard shortcut","keyboard.submit":"a Return key press","app.activated":"an app activation","session.started":"a recording-session start","session.ended":"a recording-session end","debug.error":"a collector diagnostic"]
        if evidence.kind == "keyboard.text_input", text.isEmpty, let typed=evidence.typed {
            // The words are sealed; this sentence never quotes them.
            // fix/summary-sends QF-15: the seal-time send fact, as `actions` reads it (Actions.swift): a send gesture is
            // "submitted", never "sent" (that needs a delivery receipt).
            let sendKey = evidence.captureProvenance?.unit?.send == "detected"
            summary = sendKey ? "Typed in \(evidence.app), then used its send key, \(TypedWords.bucket(typed.words))."
                : "Typed in \(evidence.app), \(TypedWords.bucket(typed.words))."
            state = sendKey ? "submitted" : "typed"
        } else if let action=recordedActions[evidence.kind] {
            summary="Recorded \(action)" + (evidence.app.isEmpty ? "." : " in \(evidence.app).")
        } else if evidence.kind == "conversation.assistant", !text.isEmpty {
            summary = "Assistant reported: \"\(text.prefixString(190))\" (not independently verified)."
            state = "reported"
        } else if evidence.kind == "conversation.user", ["i plan to ", "we plan to ", "let's plan "].contains(where: lower.hasPrefix) {
            summary = "Stated a plan: \"\(text.prefixString(190))\"."
            state = "planned"
        } else if let components = URLComponents(string: evidence.url), let encoded = components.percentEncodedQueryItems?.first(where: { ["q", "query", "search_query"].contains($0.name) })?.value, !encoded.isEmpty {
            let query = Privacy.searchValue(encoded)
            summary = "Viewed search results for \"\(Privacy.clean(query, limit: 160))\"."
            state = "viewed_search"
        } else if ["selection.changed", "terminal.value_changed"].contains(evidence.kind), !text.isEmpty {
            summary = "Observed text in \(evidence.app): \"\(text.prefixString(190))\". Authorship and completion are not established."
        } else if !text.isEmpty, ["can you ", "please ", "i want ", "help me ", "build ", "create "].contains(where: lower.hasPrefix) {
            summary = "Drafted a request in \(evidence.app): \"\(text.prefixString(190))\"."
            // A keyboard stream cannot establish that the request was actually sent.
            state = evidence.kind == "conversation.user" ? "requested" : "drafted_request"
            if state == "requested" { summary = "Asked \(evidence.app): \"\(text.prefixString(190))\"." }
        } else if !text.isEmpty {
            summary = "Entered text in \(evidence.app): \"\(text.prefixString(190))\"."
            state = "typed"
            if evidence.kind == "conversation.assistant" {
                summary = "Assistant reported: \"\(text.prefixString(190))\" (not independently verified)."
                state = "reported"
            }
        } else if evidence.bundle == BrowserSafety.supportedBundle, let host = URL(string: evidence.url)?.host, !host.isEmpty {
            // A Chrome page row: the title (or none, for search, email and chat) and the site.
            summary = evidence.title.isEmpty ? "Viewed \(host) in \(evidence.app)." : "Viewed \(evidence.title) (\(host)) in \(evidence.app)."
        } else {
            summary = "Viewed \(evidence.title.isEmpty ? evidence.app : evidence.title) in \(evidence.app)."
        }
        return MemoryItem(id: evidence.id, evidence: evidence, summary: summary, actionState: state, inference: false,
                          generatedAt: iso(now), coverageThrough: evidence.at,
                          revision: fingerprint((try? json(evidence)) ?? evidence.id), writer: "local-deterministic-1")
    }
}
