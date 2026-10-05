import Foundation
import CryptoKit

// agent-tools v2, WP-0 (integrator): the shared interface that work packages A-D build against
// (docs/agent-tools/plan.md §8, docs/agent-tools/ownership.md).
//
// This file is FROZEN for A-D. It holds data types, protocols and a few small total helpers (ids, budgets, toolset).
// Each WP fills its own namespace in its own file; the `...API` protocols below pin those signatures, so a WP that
// changes one breaks the build here instead of in another WP's branch. A change to this file goes through the
// integrator, never through a WP branch.
//
// Nothing in this file reads a store, a socket, a setting or the clock (callers pass `now`).

// MARK: - Entities (WP-B parses, everyone reads)

/// The kinds an agent can ask for (`search` `kinds`). Raw values are the tool argument spellings.
public enum AgentEntityKind: String, CaseIterable, Codable, Hashable, Sendable {
    case document, form, person
    case aiChat = "ai_chat"
    case webSearch = "web_search"
    case email, terminal, page, feed, app
}

/// What one read-time item is about (plan §5.2). Derived at read time from a `CanonicalAction` and its typed facts;
/// never stored.
public enum AgentEntity: Hashable, Codable, Sendable {
    public enum DocumentKind: String, Codable, Hashable, Sendable {
        case doc, sheet, slides, form, drive
        /// Integrator (0.1.5): documents outside Google Workspace, named by the app or site they are in.
        case notion, airtable, pages, word, textedit, numbers, excel, keynote, powerpoint
        /// Where the document is, as a reply says it: "Google Docs", "Notion", "Pages"; a form is just "form".
        public var place: String {
            switch self {
            case .doc: return "Google Docs"
            case .sheet: return "Google Sheets"
            case .slides: return "Google Slides"
            case .drive: return "Google Drive"
            case .form: return "form"
            case .notion: return "Notion"
            case .airtable: return "Airtable"
            case .pages: return "Pages"
            case .word: return "Word"
            case .textedit: return "TextEdit"
            case .numbers: return "Numbers"
            case .excel: return "Excel"
            case .keynote: return "Keynote"
            case .powerpoint: return "PowerPoint"
            }
        }
    }
    case document(kind: DocumentKind, name: String)
    /// `query` nil: a site-only search row ("searched on Google").
    case webSearch(engine: String, query: String?)
    case aiChat(app: String, title: String?)
    case person(name: String)
    /// `subject` nil: a mailbox view (collapsed).
    case email(subject: String?)
    /// `host` is already the stable alias `host-<4 base32>`, never a real host name or address.
    case terminal(tool: String?, project: String?, host: String?)
    case feed(site: String)
    case page(title: String, site: String)
    /// `lowValue`: system UI and DayDream's own windows.
    case app(name: String, title: String, lowValue: Bool)

    public var kind: AgentEntityKind {
        switch self {
        case .document(let k, _): return k == .form ? .form : .document
        case .webSearch: return .webSearch
        case .aiChat: return .aiChat
        case .person: return .person
        case .email: return .email
        case .terminal: return .terminal
        case .feed: return .feed
        case .page: return .page
        case .app: return .app
        }
    }
}

/// `AgentEntity.key` (WP-B, AgentEntities.swift): the stable grouping string ids are hashed from.
public protocol AgentEntityKeyed { var key: String { get } }
extension AgentEntity: AgentEntityKeyed {}

// MARK: - Typed facts and day input (pure inputs to WP-B)

/// Metadata of one typed action (never words): its seal facts and its word count.
public struct AgentTypedFact: Equatable {
    public var actionID: String
    public var unit: TypedUnitProvenance?
    public var words: Int
    public init(actionID: String, unit: TypedUnitProvenance?, words: Int) {
        self.actionID = actionID; self.unit = unit; self.words = words
    }
}

/// One stored moment note's lines and the actions it covers (read-only use of existing notes, plan §5.3).
public struct AgentNoteInput: Equatable, Sendable {
    public var actionIDs: [String]
    public var lines: [String]
    public init(actionIDs: [String], lines: [String]) { self.actionIDs = actionIDs; self.lines = lines }
}

/// Everything `AgentItems.items` needs for one local day. `day` is "yyyy-MM-dd" in `timezone`.
public struct AgentDayInput {
    public var day: String
    public var timezone: String
    public var actions: [CanonicalAction]
    /// By action id.
    public var typed: [String: AgentTypedFact]
    public var notes: [AgentNoteInput]
    public init(day: String, timezone: String, actions: [CanonicalAction], typed: [String: AgentTypedFact] = [:], notes: [AgentNoteInput] = []) {
        self.day = day; self.timezone = timezone; self.actions = actions; self.typed = typed; self.notes = notes
    }
}

// MARK: - Items (WP-B builds, WP-C ranks into replies)

public struct AgentVisit: Codable, Equatable, Sendable {
    public var start: Date
    public var end: Date
    public init(start: Date, end: Date) { self.start = start; self.end = end }
}

/// One thing the person did in a day: all visits of one entity (plan §5.3).
public struct AgentItem: Codable, Equatable, Sendable {
    /// `AgentItemID` form, e.g. "1004-k7f2q".
    public var id: String
    public var day: String
    public var entity: AgentEntity
    public var firstAt: Date
    public var lastAt: Date
    public var visits: [AgentVisit]
    public var minutes: Double
    /// Internal only (notes overlap, details). Never rendered.
    public var actionIDs: [String]
    public var typedIDs: [String]
    public var typedWords: Int
    /// Already filtered (§5.3): no filler, no send states.
    public var noteLines: [String]
    public var score: Double
    public var visitCount: Int { visits.count }
    public init(id: String, day: String, entity: AgentEntity, firstAt: Date, lastAt: Date, visits: [AgentVisit], minutes: Double,
                actionIDs: [String], typedIDs: [String], typedWords: Int, noteLines: [String], score: Double) {
        self.id = id; self.day = day; self.entity = entity; self.firstAt = firstAt; self.lastAt = lastAt; self.visits = visits
        self.minutes = minutes; self.actionIDs = actionIDs; self.typedIDs = typedIDs; self.typedWords = typedWords
        self.noteLines = noteLines; self.score = score
    }
}

// MARK: - Stable ids (plan §2), implemented here: shared by B (makes) and C (decodes)

public enum AgentItemID {
    static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")
    /// `<MMDD>-<base32(sha256(day + "\n" + key))>` with `length` (5, or 6 on a same-day collision) characters.
    public static func make(day: String, key: String, length: Int = 5) -> String {
        let digest = Array(SHA256.hash(data: Data((day + "\n" + key).utf8)))
        var bits = 0, value = 0, out = ""
        for byte in digest where out.count < length {
            value = (value << 8) | Int(byte); bits += 8
            while bits >= 5 && out.count < length { bits -= 5; out.append(alphabet[(value >> bits) & 31]) }
            value &= (1 << bits) - 1
        }
        let mmdd = day.split(separator: "-").dropFirst().joined()
        return mmdd + "-" + out
    }
    /// Ids for one day's keys: 5 characters, 6 for every key whose 5-character id collides. Deterministic per input.
    public static func assign(day: String, keys: [String]) -> [String: String] {
        var short: [String: [String]] = [:]
        for key in Set(keys) { short[make(day: day, key: key), default: []].append(key) }
        var out: [String: String] = [:]
        for (id, members) in short {
            if members.count == 1 { out[members[0]] = id } else { for key in members { out[key] = make(day: day, key: key, length: 6) } }
        }
        return out
    }
    /// True for `^\d{4}-[a-z2-7]{5,6}$`.
    public static func isValid(_ id: String) -> Bool {
        id.range(of: #"^\d{4}-[a-z2-7]{5,6}$"#, options: .regularExpression) != nil
    }
    /// The local day ("yyyy-MM-dd") an id names: the most recent such MMDD that is not after `now`'s day in `timezone`.
    public static func day(of id: String, now: Date, timezone: String) -> String? {
        guard isValid(id), let tz = TimeZone(identifier: timezone) else { return nil }
        let mm = Int(id.prefix(2)) ?? 0, dd = Int(id.dropFirst(2).prefix(2)) ?? 0
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        let today = cal.dateComponents([.year, .month, .day], from: now)
        guard let year = today.year else { return nil }
        for y in [year, year - 1] {
            var c = DateComponents(); c.year = y; c.month = mm; c.day = dd
            guard let date = cal.date(from: c), cal.component(.month, from: date) == mm, cal.component(.day, from: date) == dd else { continue }
            if cal.startOfDay(for: date) <= cal.startOfDay(for: now) { return String(format: "%04d-%02d-%02d", y, mm, dd) }
        }
        return nil
    }
}

// MARK: - Typed source (WP-A's bridge client; WP-D's in-process fixture)

public enum AgentVaultState: String, Codable, Sendable { case ready, locked, unavailable }

/// The bridge op `policy` answer. `reachable` false: no socket answer (DayDream isn't open).
public struct AgentBridgePolicy: Equatable, Sendable {
    public var reachable: Bool
    public var typedWords: Bool
    public var vault: AgentVaultState
    public init(reachable: Bool, typedWords: Bool, vault: AgentVaultState) {
        self.reachable = reachable; self.typedWords = typedWords; self.vault = vault
    }
    public static let unreachable = AgentBridgePolicy(reachable: false, typedWords: false, vault: .unavailable)
}

public struct AgentTypedHit: Codable, Equatable, Sendable {
    public var id: String
    public var at: String
    /// Already through `AgentSharePolicy.shareable`.
    public var snippet: String
    public init(id: String, at: String, snippet: String) { self.id = id; self.at = at; self.snippet = snippet }
}

public struct AgentTypedSearchResult: Equatable, Sendable {
    public var hits: [AgentTypedHit]
    public var total: Int
    /// false only after the 3 s wall clock; `oldestScanned` then says how far back the scan got.
    public var complete: Bool
    public var oldestScanned: String?
    public init(hits: [AgentTypedHit], total: Int, complete: Bool, oldestScanned: String? = nil) {
        self.hits = hits; self.total = total; self.complete = complete; self.oldestScanned = oldestScanned
    }
    public static let empty = AgentTypedSearchResult(hits: [], total: 0, complete: true)
}

/// Where typed words come from: the app's bridge (WP-A `AgentBridgeSource`) or an in-process fixture (WP-D).
/// Words returned are already shareable (through the policy); an id with nothing to share is left out.
public protocol AgentTypedSource {
    func policy() -> AgentBridgePolicy
    func words(_ ids: [String]) throws -> [String: String]
    func search(_ query: String, start: Date?, end: Date?, limit: Int?) throws -> AgentTypedSearchResult
}

// MARK: - Bridge request and the local-owner preview (owner decision 10/04, plan §6.3)

public enum AgentBridgeOp: String, Codable, Sendable { case policy, words, search }

/// One request on the app's local socket, as WP-A's client sends it and the app's bridge reads it.
public struct AgentBridgeRequest: Equatable, Sendable {
    public var op: AgentBridgeOp
    public var ids: [String]
    public var query: String?
    public var start: Date?
    public var end: Date?
    public var limit: Int?
    /// The MCP client's grant fields; all "" for an owner preview.
    public var client: String
    public var recipient: String
    public var capability: String
    /// The local-owner preview. True ONLY when the owner passed `AgentOwnerPreview.cliFlag` to
    /// `mac-mem --local agent-preview` on their own Mac. Never set by `mac-mem mcp` or any AI-app path.
    public var ownerPreview: Bool
    public init(op: AgentBridgeOp, ids: [String] = [], query: String? = nil, start: Date? = nil, end: Date? = nil, limit: Int? = nil,
                client: String = "", recipient: String = "", capability: String = "", ownerPreview: Bool = false) {
        self.op = op; self.ids = ids; self.query = query; self.start = start; self.end = end; self.limit = limit
        self.client = client; self.recipient = recipient; self.capability = capability; self.ownerPreview = ownerPreview
    }
}

/// The local-owner preview: lets a command the owner runs on their own Mac read their own typed words (for
/// `scripts/agent-tools-private-run.py`, whose output stays under the owner's private folder). It is never an MCP path.
/// The app honors it only when ALL hold: the socket peer is the same user (already enforced), the request came over
/// the local socket, `ownerPreview` is true, `client`/`recipient`/`capability` are all "", the process is not
/// `mac-mem mcp`, and the typed-words setting is on. Everything still goes through `AgentSharePolicy.shareable`.
public enum AgentOwnerPreview {
    /// The explicit flag the owner passes: `mac-mem --local agent-preview --owner-preview <tool> <json-args>`.
    public static let cliFlag = "--owner-preview"
    /// The request field on the socket.
    public static let requestKey = "owner"
}

/// WP-A (AgentBridgeSource.swift): the app-side gate for an owner preview. `sameUser`: the socket peer's uid is the
/// app's; `fromMCPServer`: the request came from a `mac-mem mcp` process; `typedWordsSetting`: the app setting, read now.
public protocol AgentOwnerPreviewAPI {
    static func permits(_ request: AgentBridgeRequest, sameUser: Bool, fromMCPServer: Bool, typedWordsSetting: Bool) -> Bool
}
extension AgentOwnerPreview: AgentOwnerPreviewAPI {}

/// No words, ever: typing off, or nothing to ask.
public struct AgentNoTypedSource: AgentTypedSource {
    public var answer: AgentBridgePolicy
    public init(_ answer: AgentBridgePolicy = .unreachable) { self.answer = answer }
    public func policy() -> AgentBridgePolicy { answer }
    public func words(_ ids: [String]) throws -> [String: String] { [:] }
    public func search(_ query: String, start: Date?, end: Date?, limit: Int?) throws -> AgentTypedSearchResult { .empty }
}

// MARK: - Share policy (WP-A fills the behavior in AgentSharePolicy.swift)

public struct AgentSharePolicy: Equatable, Sendable {
    public enum Redaction: String, CaseIterable, Codable, Sendable {
        case secureFields, oneTimeCodes, apiKeysAndTokens, privateKeys, cardNumbers, governmentIDs, urlCredentials
    }
    /// Why typed words are not shared; nil while they are.
    public enum TypedWordsOff: String, Codable, Sendable { case settingOff, appClosed, locked }
    public static let defaultOmittedKinds: Set<String> = [
        "mouse.click", "mouse.context_menu", "keyboard.shortcut", "keyboard.submit", "app.activated", "idle",
        "session.*", "debug.error", "*scroll*",
    ]

    public var typedWords: Bool
    public var typedWordsOff: TypedWordsOff?
    public var redactions: [Redaction]
    public var omittedKinds: Set<String>
    /// Never sent/draft/unsent/delivered to agents. A constant, kept so `status` and the checks can read it.
    public let sendStateShown: Bool = false

    public init(typedWords: Bool, typedWordsOff: TypedWordsOff? = nil, redactions: [Redaction] = Redaction.allCases,
                omittedKinds: Set<String> = AgentSharePolicy.defaultOmittedKinds) {
        self.typedWords = typedWords
        self.typedWordsOff = typedWords ? nil : (typedWordsOff ?? .appClosed)
        self.redactions = redactions; self.omittedKinds = omittedKinds
    }

    /// True when rows of this action kind never reach an agent. Patterns: exact, `prefix.*`, `*part*`.
    public func omits(_ kind: String) -> Bool {
        omittedKinds.contains { p in
            if p.hasPrefix("*") && p.hasSuffix("*") && p.count > 2 { return kind.contains(p.dropFirst().dropLast()) }
            if p.hasSuffix(".*") { return kind.hasPrefix(p.dropLast()) }
            return kind == p
        }
    }
}

/// WP-A, AgentSharePolicy.swift. `shareable` is the ONLY function that turns stored typed text into agent text.
public protocol AgentSharePolicyAPI {
    static func current(bridge: AgentTypedSource) -> AgentSharePolicy
    /// nil: share nothing for this unit.
    func shareable(_ raw: String) -> String?
    /// The `status` "shared" lines, generated from this value.
    func statusLines() -> [String]
}
extension AgentSharePolicy: AgentSharePolicyAPI {}

/// WP-A, AgentSharePolicy.swift: plain words for `status` ("passwords and secure fields", ...).
public protocol AgentRedactionPlain { var plain: String { get } }
extension AgentSharePolicy.Redaction: AgentRedactionPlain {}

// MARK: - Read-time model namespaces (WP-B fills each in its own file)

public enum AgentTitles {}
public enum AgentEntities {}
public enum AgentItems {}
public enum AgentRank {}

/// WP-B, AgentTitles.swift.
public protocol AgentTitlesAPI {
    static func normalized(_ title: String, app: String, site: String) -> String
    /// `normalized` plus case and digit-tail folding, for collapsing flicker.
    static func flickerKey(_ title: String, app: String, site: String) -> String
}
extension AgentTitles: AgentTitlesAPI {}

/// WP-B, AgentEntities.swift.
public protocol AgentEntitiesAPI {
    static func entity(_ action: CanonicalAction, unit: TypedUnitProvenance?) -> AgentEntity
}
extension AgentEntities: AgentEntitiesAPI {}

/// WP-B, AgentItems.swift.
public protocol AgentItemsAPI {
    /// One day's items, ids assigned (`AgentItemID.assign`), scored (`AgentRank.score`), highest first.
    static func items(_ day: AgentDayInput, policy: AgentSharePolicy, now: Date) -> [AgentItem]
    /// One stored note line as an agent may see it (§5.3), or nil when it is dropped. `itemName`: the item's own name.
    static func noteLine(_ line: String, itemName: String) -> String?
}
extension AgentItems: AgentItemsAPI {}

/// WP-B, AgentRank.swift.
public protocol AgentRankAPI {
    static func score(_ item: AgentItem, now: Date) -> Double
}
extension AgentRank: AgentRankAPI {}

// MARK: - Tools, replies and rendering (WP-C)

/// `DAYDREAM_MCP_TOOLSET`: v2 (default), legacy, or both.
public enum ToolsetMode: String, CaseIterable, Sendable {
    case v2, legacy, both
    public static let environmentKey = "DAYDREAM_MCP_TOOLSET"
    public static func current(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> ToolsetMode {
        environment[environmentKey].flatMap { ToolsetMode(rawValue: $0.lowercased()) } ?? .v2
    }
    /// Tools listed by tools/list in this mode (legacy names still answer under v2, unlisted).
    public var listed: [String] {
        switch self {
        case .v2: return AgentToolName.allCases.map(\.rawValue)
        case .legacy: return Self.legacyNames + ["status"]
        case .both: return AgentToolName.allCases.map(\.rawValue) + Self.legacyNames
        }
    }
    /// The 0.1.4 tool names that keep answering for one release.
    public static let legacyNames = ["recap", "recall", "open", "read", "context", "current-context", "moment_details"]
}

public enum AgentToolName: String, CaseIterable, Codable, Sendable { case timeline, search, details, status }

public enum AgentFormat: String, Codable, Sendable { case text, json }
public enum AgentDetail: String, Codable, Sendable { case summary, full }

public struct AgentTimelineArgs: Equatable, Sendable {
    /// today, yesterday, a weekday, this week, last week, a date, or "A to B" (at most 7 days).
    public var when: String
    public var detail: AgentDetail
    public var cursor: String?
    public init(when: String = "today", detail: AgentDetail = .summary, cursor: String? = nil) {
        self.when = when; self.detail = detail; self.cursor = cursor
    }
}

public struct AgentSearchArgs: Equatable, Sendable {
    public var query: String
    public var kinds: Set<AgentEntityKind>
    public var when: String?
    public var limit: Int
    public var cursor: String?
    public init(query: String, kinds: Set<AgentEntityKind> = [], when: String? = nil, limit: Int = 20, cursor: String? = nil) {
        self.query = query; self.kinds = kinds; self.when = when; self.limit = limit; self.cursor = cursor
    }
}

public struct AgentDetailsArgs: Equatable, Sendable {
    public var id: String
    public var cursor: String?
    public init(id: String, cursor: String? = nil) { self.id = id; self.cursor = cursor }
}

public enum AgentToolCall: Equatable, Sendable {
    case timeline(AgentTimelineArgs)
    case search(AgentSearchArgs)
    case details(AgentDetailsArgs)
    case status
}

/// The day's headline for `timeline`, read-only. `MemoryStore` conforms (AgentHeadline.swift, integrator): the stored day
/// note's headline, as the app's day card shows it.
public protocol DayReviewHeadlineSource {
    func dayReviewHeadline(day: String, timezone: String) throws -> String?
    /// nil, too, when the headline was written from typed rows and typed words aren't shared now.
    func dayReviewHeadline(day: String, timezone: String, typedWords: Bool) throws -> String?
}
extension DayReviewHeadlineSource {
    public func dayReviewHeadline(day: String, timezone: String, typedWords: Bool) throws -> String? {
        try dayReviewHeadline(day: day, timezone: timezone)
    }
}

/// What a tool call runs against.
public struct AgentToolContext {
    public var store: MemoryStore
    public var typed: AgentTypedSource
    public var headlines: DayReviewHeadlineSource?
    public var timezone: String
    public var now: Date
    public init(store: MemoryStore, typed: AgentTypedSource, headlines: DayReviewHeadlineSource? = nil, timezone: String, now: Date) {
        self.store = store; self.typed = typed; self.headlines = headlines; self.timezone = timezone; self.now = now
    }
}

/// The last header segment: absent while notes are on.
public enum AgentNotesState: Codable, Equatable, Sendable {
    case on, paused
    case catchingUp(Int)
}

/// `DayDream · Sun Oct 4, 4:52 PM CDT · recorded Oct 1 – Oct 4 · notes paused`
public struct AgentHeader: Codable, Equatable, Sendable {
    public var now: Date
    public var timezone: String
    public var recordedFrom: Date?
    public var recordedTo: Date?
    public var notes: AgentNotesState
    public init(now: Date, timezone: String, recordedFrom: Date?, recordedTo: Date?, notes: AgentNotesState) {
        self.now = now; self.timezone = timezone; self.recordedFrom = recordedFrom; self.recordedTo = recordedTo; self.notes = notes
    }
}

/// Items not listed, counted by kind (`Collapsed: 3 documents, 41 app windows, 2 feeds`). Counts add up to `total`.
public struct AgentCollapsed: Codable, Equatable, Sendable {
    public var total: Int
    public var byKind: [AgentEntityKind: Int]
    public init(total: Int = 0, byKind: [AgentEntityKind: Int] = [:]) { self.total = total; self.byKind = byKind }
}

public struct AgentTimelineDay: Codable, Equatable, Sendable {
    public var day: String
    public var headline: String?
    public var items: [AgentItem]
    public var collapsed: AgentCollapsed
    public init(day: String, headline: String?, items: [AgentItem], collapsed: AgentCollapsed) {
        self.day = day; self.headline = headline; self.items = items; self.collapsed = collapsed
    }
}

public struct AgentTimelineReply: Codable, Equatable, Sendable {
    public var detail: AgentDetail
    public var days: [AgentTimelineDay]
    public var cursor: String?
    public init(detail: AgentDetail, days: [AgentTimelineDay], cursor: String? = nil) {
        self.detail = detail; self.days = days; self.cursor = cursor
    }
}

public struct AgentSearchReply: Codable, Equatable, Sendable {
    public var query: String
    /// Items matching (the complete count when `complete`).
    public var total: Int
    public var totalVisits: Int
    public var offset: Int
    public var items: [AgentItem]
    /// Present only when more items exist.
    public var cursor: String?
    public var complete: Bool
    /// Plain reason when not complete (e.g. the scan's hard stop and how far back it got).
    public var incompleteReason: String?
    public init(query: String, total: Int, totalVisits: Int, offset: Int, items: [AgentItem], cursor: String?, complete: Bool,
                incompleteReason: String? = nil) {
        self.query = query; self.total = total; self.totalVisits = totalVisits; self.offset = offset; self.items = items
        self.cursor = cursor; self.complete = complete; self.incompleteReason = incompleteReason
    }
}

/// How one typed line is framed (plan §6.1). Never a send state.
public enum AgentTypedLineForm: Codable, Equatable, Sendable {
    case texted(name: String)
    case asked(app: String)
    case searched(engine: String)
    case typedIn(place: String)
    case ran(project: String)
}

public struct AgentTypedLine: Codable, Equatable, Sendable {
    public var at: Date
    public var form: AgentTypedLineForm
    /// Already through `AgentSharePolicy.shareable`.
    public var text: String
    public init(at: Date, form: AgentTypedLineForm, text: String) { self.at = at; self.form = form; self.text = text }
}

public struct AgentDetailsReply: Codable, Equatable, Sendable {
    public var item: AgentItem
    public var typedLines: [AgentTypedLine]
    public var related: [AgentItem]
    public var cursor: String?
    public init(item: AgentItem, typedLines: [AgentTypedLine], related: [AgentItem], cursor: String? = nil) {
        self.item = item; self.typedLines = typedLines; self.related = related; self.cursor = cursor
    }
}

public struct AgentStatusReply: Codable, Equatable, Sendable {
    public var recording: String
    public var connection: String
    /// Exactly `AgentSharePolicy.statusLines()`.
    public var shared: [String]
    public var notes: AgentNotesState
    public var recordedFrom: Date?
    public var recordedTo: Date?
    public var examples: [String]
    public init(recording: String, connection: String, shared: [String], notes: AgentNotesState, recordedFrom: Date?, recordedTo: Date?,
                examples: [String]) {
        self.recording = recording; self.connection = connection; self.shared = shared; self.notes = notes
        self.recordedFrom = recordedFrom; self.recordedTo = recordedTo; self.examples = examples
    }
}

public struct AgentReply: Codable, Equatable, Sendable {
    public enum Body: Codable, Equatable, Sendable {
        case timeline(AgentTimelineReply)
        case search(AgentSearchReply)
        case details(AgentDetailsReply)
        case status(AgentStatusReply)
        /// "not found: it may have been forgotten", a bad argument, etc. Plain words, no ids.
        case message(String)
    }
    public var header: AgentHeader
    public var body: Body
    public init(header: AgentHeader, body: Body) { self.header = header; self.body = body }
}

/// Token budgets (plan §2): tokens = UTF-8 bytes / 4.
public enum AgentBudget {
    public static let timelineSummary = 1_500
    public static let timelineFull = 4_000
    public static let search = 3_000
    public static let details = 3_000
    public static let status = 800
    public static func tokens(_ text: String) -> Int { text.utf8.count / 4 }
}

public struct AgentRenderInput {
    public var reply: AgentReply
    public var format: AgentFormat
    /// In tokens (`AgentBudget`).
    public var budget: Int
    public init(reply: AgentReply, format: AgentFormat, budget: Int) { self.reply = reply; self.format = format; self.budget = budget }
}

public struct AgentRendered: Equatable, Sendable {
    public var text: String
    /// Items (or lines) left out to fit the budget; the text says so when > 0.
    public var omitted: Int
    public init(text: String, omitted: Int) { self.text = text; self.omitted = omitted }
}

public enum AgentTools {}
public enum AgentRender {}

/// WP-C, AgentTools.swift.
public protocol AgentToolsAPI {
    static func call(_ call: AgentToolCall, context: AgentToolContext) throws -> AgentReply
    /// A tools/call `arguments` object for one v2 tool name; nil for an unknown name.
    static func parse(name: String, arguments: [String: Any]) throws -> AgentToolCall?
}
extension AgentTools: AgentToolsAPI {}

/// WP-C, AgentRender.swift. Never emits `macmem://`, bundle ids, revision, epoch, snapshot or evidence ids.
public protocol AgentRenderAPI {
    static func render(_ input: AgentRenderInput) -> AgentRendered
    static func header(_ header: AgentHeader) -> String
}
extension AgentRender: AgentRenderAPI {}
