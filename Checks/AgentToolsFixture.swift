import Foundation
import MemoryCore
import PrivacyPolicy

// agent-tools v2, WP-D (docs/agent-tools/plan.md §7): one synthetic week for the AI-app tool evals.
//
// A made-up founder building "Tallybird" (bookkeeping software) and filling in the "Northwind Fellowship application".
// Every name, title, address, key and word below is invented. The fixture writes through the public store API only
// (`MemoryStore.ingest`, `commitNote`), into a temp home, with an in-memory typing key (`attachTestVault`): typed words
// are sealed for real and never sit in a record body.
//
// The week (America/Chicago), "now" = Sun Oct 4 2026, 4:52 PM:
// - Mon Sep 28  the 1,000-moment day: 1,000+ distinct windows, 40 "Kestrel interview" notes, an investor update doc.
// - Tue Sep 29  the summaries-off day: work with no notes at all (the evals switch the writer off for it).
// - Wed Sep 30  empty: nothing recorded.
// - Thu Oct 1   a realistic day: an office-hours form, the application draft, 17 more Kestrel notes, claude.ai.
// - Fri Oct 2   empty.
// - Sat Oct 3   yesterday (standup): runway sheet, pricing memo (3 visits, last 5:40 PM), ChatGPT, Mail, Terminal with
//               Claude Code and an ssh host, three Google searches, a billing article, a short feed.
// - Sun Oct 4   today: a 90-second Google Form vs a 60-minute X feed, the application draft (answers typed in Notes), Claude desktop and claude.ai
//               prompts, texts with three people, Mail, Terminal, Finder, stray Return presses, and a Notes row that
//               holds secrets (an sk- key, a 2FA code, a card number, URL credentials, a JWT).
//
// Typing lanes. The public lane (no owner flags) types only in Notes and TextEdit, so typed rows in Messages, Claude,
// ChatGPT, Terminal, Mail and Chrome are refused at the store there; the fixture records which were kept
// (`typedKept`/`typedRefused`) and the evals that need them report "n/a (public lane)". The secrets row is in Notes, so
// redaction is checked in both lanes.

public struct AgentToolsFixtureManifest: Codable {
    public var marker = AgentToolsFixture.marker
    public var timezone: String
    public var now: String
    public var days: [String: String]
    public var lane: String
    public var typedKept: [String]
    public var typedRefused: [String]
    public var secrets: [String]
    public var secretNeighbours: [String]
    public var counts: [String: Int]
    public var facts: [String: String]
}

/// The typed-words source the tools read in-process: WP-A's `AgentStoreTypedSource` on the fixture's own store (which
/// holds the test key), read with a fixture grant exactly as the app's bridge answers an AI app: the same policy, the
/// same errors, no socket. Only the two app-side states the store can't know stay here: `reachable` (false = DayDream
/// isn't open, no socket answer) and the "Let AI apps read what you typed" setting.
public final class AgentToolsFixtureTypedSource: AgentTypedSource {
    let store: MemoryStore
    let now: Date
    let reader: TypedReader
    /// The app's "Let AI apps read what you typed" setting, as the bridge would read it.
    public var typedWordsSetting = true
    /// false: behave as if DayDream isn't open (no socket answer).
    public var reachable = true
    /// The test vault's key store: `locked = true` plus `reconcileTypedVault` is "typing locked".
    var keys: InMemoryTypedKeyStore?
    init(store: MemoryStore, reader: TypedReader, now: Date) { self.store = store; self.reader = reader; self.now = now }

    var source: AgentStoreTypedSource { AgentStoreTypedSource(store: store, reader: reader, enabled: typedWordsSetting, now: now) }
    public func policy() -> AgentBridgePolicy {
        guard reachable else { return .unreachable }
        return source.policy()
    }
    /// Lock or unlock typing, as the app's vault would after the key became unreadable.
    public func setLocked(_ locked: Bool) throws {
        guard let keys, keys.locked != locked else { return }
        keys.locked = locked
        _ = try store.reconcileTypedVault(now: now)
    }
    public func words(_ ids: [String]) throws -> [String: String] {
        guard reachable else { throw AgentBridgeError.unavailable(.appClosed) }
        return try source.words(ids)
    }
    public func search(_ query: String, start: Date?, end: Date?, limit: Int?) throws -> AgentTypedSearchResult {
        guard reachable else { throw AgentBridgeError.unavailable(.appClosed) }
        return try source.search(query, start: start, end: end, limit: limit)
    }
}

public final class AgentToolsFixture {
    public static let marker = "daydream-agenttools-synthetic-fixture-v1"
    public static let manifestName = "agenttools-fixture.json"
    public static let timezone = "America/Chicago"
    /// Sun Oct 4 2026, 4:52 PM CDT.
    public static let now = Date(timeIntervalSince1970: 1_791_150_720)

    public enum Day: String, CaseIterable {
        case busy = "2026-09-28", notesOff = "2026-09-29", empty = "2026-09-30", thursday = "2026-10-01", friday = "2026-10-02"
        case yesterday = "2026-10-03", today = "2026-10-04"
    }

    // People, places and words (all made up).
    static let sam = "Sam Okafor", priya = "Priya Raman", jules = "Jules Moreau"
    /// Known only from a typed row's own recipient (the Messages window shows no name): gone when typed words are off.
    static let dana = "Dana Whitfield"
    static let textToDana = "thanks again for the intro to the Northwind partners, I owe you a coffee"
    static let form = "Northwind Fellowship application"
    static let officeHoursForm = "Founder office hours signup"
    static let draftDoc = "Northwind application draft"
    static let answersNote = "Northwind application answers"
    static let pricingMemo = "Tallybird pricing memo"
    static let runwaySheet = "Tallybird runway"
    static let hiringDoc = "Tallybird hiring plan"
    static let investorDoc = "Tallybird investor update"
    static let searchWord = "Kestrel"
    static let busyWindows = 1_300
    static let searches = ["northwind fellowship deadline", "delaware franchise tax due date", "stripe usage based billing"]
    static let article = "Usage-based billing for early startups"
    static let articleSite = "https://www.ledgerline.dev"
    static let mailSubjects = ["Re: Tallybird pilot pricing", "Invoice 2041 from Fernhill Studio", "Northwind Fellowship: references due Oct 9"]
    static let claudePrompt = "how should I answer the Northwind question about traction when we only have 40 pilot users and two paying firms?"
    static let claudeWebPrompt = "what are good questions to ask a fellowship interviewer at the end of a 20 minute call?"
    static let chatGPTPrompt = "rewrite this so it sounds less salesy: Tallybird closes your books in a day, not a week"
    static let hiringText = "can we talk hiring after lunch, I drafted the plan"
    static let textToSam = "sent the Northwind draft to you, can you read the traction answer before 6 tonight"
    static let textToPriya = "would you be a reference for Northwind? the form asks for two names by Friday"
    static let textToJules = "the new owl logo looks great, ship it on the landing page"
    static let mailReply = "Thanks Dana, 49 dollars per seat works for the pilot if we can start on the 12th"
    static let terminalCommand = "fix the failing invoice export test in tallybird-api"
    /// Long on purpose: details must show it whole, the timeline only an excerpt.
    static let draftTyping = "Tallybird helps independent bookkeepers close the month in one day instead of five. We started with forty pilot users from two accounting firms, and both firms now pay for every seat. The next twelve months are about the reconciliation engine, a shared review queue, and onboarding the first hundred firms without hiring a sales team."
    static let notesSecretsText = "staging key for Dana is sk-proj-Fx8Qa1Lm3Nz7Wc5Vb2Tr9Yp4Hd6Js0Ke and the login code was 482913, the Figma renewal card 4242 4242 4242 4242, deploy url https://deploy:hunter2pass@staging.tallybird.dev and token eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0YWxseWJpcmQifQ.c2lnbmF0dXJlZml4dHVyZWFiYw remember the launch checklist"
    static let secrets = ["sk-proj-Fx8Qa1Lm3Nz7Wc5Vb2Tr9Yp4Hd6Js0Ke", "482913", "4242 4242 4242 4242", "4242424242424242", "hunter2pass",
                          "deploy:hunter2pass", "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJ0YWxseWJpcmQifQ", "731942"]
    static let secretNeighbours = ["staging key", "launch checklist"]
    static let textWithCode = "the Figma code is 731942 if you need to get in tonight"
    static let sshTitle = "dev@10.0.0.7: ~/tallybird-api — ssh — 120×40"
    static let claudeCodeTitle = "tallybird-api — claude — 120×40"
    static let kestrelNames = ["Avery", "Blake", "Cora", "Dmitri", "Elena", "Farah", "Gus", "Hana", "Ivo", "Jada", "Kenji", "Lena", "Milo", "Nadia",
                               "Oren", "Pia", "Quinn", "Rosa", "Silas", "Tess", "Umar", "Vera", "Wes", "Xena", "Yusuf", "Zara", "Abel", "Bea",
                               "Cyrus", "Dalia", "Emil", "Flora", "Gideon", "Hollis", "Ines", "Jonah", "Kira", "Luca", "Mae", "Nico", "Odette",
                               "Paz", "Ravi", "Sunniva", "Tobias", "Ulla", "Viggo", "Wren", "Ximena", "Yara", "Zeke", "Alba", "Bruno", "Celine",
                               "Dario", "Edda", "Fausto"]

    public let home: URL
    public let store: MemoryStore
    public let typed: AgentToolsFixtureTypedSource
    public private(set) var typedKept: [String] = []
    public private(set) var typedRefused: [String] = []
    public private(set) var counts: [String: Int] = [:]
    public private(set) var facts: [String: String] = [:]
    var rows: [Evidence] = []
    var seq = 0

    public var timezone: String { Self.timezone }
    public var now: Date { Self.now }
    /// The typing lane: true where this build types in Messages, Claude, Terminal, Mail and Chrome (owner flags).
    public static var typingAppsOpen: Bool { TypingRelease.open }

    /// A read-only store on the same home, as `mac-mem mcp` opens it (no typing key).
    public func reader() throws -> MemoryStore { try MemoryStore(home: home, automaticallySyncSearch: false) }
    public func context(typed source: AgentTypedSource? = nil) throws -> AgentToolContext {
        let store = try reader()
        // The day headline as the MCP server reads it (`MemoryStore: DayReviewHeadlineSource`).
        return AgentToolContext(store: store, typed: source ?? typed, headlines: store, timezone: timezone, now: now)
    }

    init(home: URL, store: MemoryStore, reader: TypedReader) {
        self.home = home; self.store = store; self.typed = AgentToolsFixtureTypedSource(store: store, reader: reader, now: Self.now)
    }

    // MARK: Build

    public static func build(home: URL) throws -> AgentToolsFixture {
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        var policy = try store.policy()
        policy.captureText = true; policy.typedConsentVersion = 1
        policy.browserPages = true; policy.browserPagesConsentVersion = PrivacySettings.browserPagesConsentCurrent
        try store.updatePolicy(policy, now: now)
        let keys = try attachTestVault(store)
        try store.acceptSafeTyping(now: now)
        // The AI app the in-process source reads as (a fixture grant in the temp home).
        let capability = try store.grant(client: "agenttools-fixture", recipient: "local", scopes: MemoryStore.assistantScopes)
        let f = AgentToolsFixture(home: home, store: store, reader: TypedReader(client: "agenttools-fixture", recipient: "local", capability: capability))
        f.typed.keys = keys
        try f.writeWeek()
        try f.writeNotes()
        try store.setSummaryWriter("local", now: now)
        try f.writeManifest()
        return f
    }

    func date(_ day: Day, _ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: Self.timezone)!
        let parts = day.rawValue.split(separator: "-").map { Int($0)! }
        return cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: h, minute: m, second: s))!
    }
    func nextID(_ prefix: String) -> String { seq += 1; return String(format: "%@-%05d", prefix, seq) }

    // Row shapes.
    func window(_ t: Date, _ app: String, _ bundle: String, _ title: String, tool: String? = nil) -> Evidence {
        var e = Evidence(id: nextID("w"), at: iso(t), kind: "window.changed", app: app, bundle: bundle, title: title, synthetic: true)
        e.titleTool = tool
        return e
    }
    func event(_ t: Date, _ kind: String, _ app: String, _ bundle: String, _ title: String = "") -> Evidence {
        Evidence(id: nextID("k"), at: iso(t), kind: kind, app: app, bundle: bundle, title: title, synthetic: true)
    }
    func page(_ t: Date, _ title: String, _ origin: String, tab: String = "1733") -> Evidence {
        var proof = BrowserVerification(mode: "normal", windowID: "1520", tabID: tab, focusedRole: "", checkedAt: isoPrecise(t), provider: BrowserSafety.pageProvider)
        proof.policyRevision = "policy-fixture"
        return Evidence(id: nextID("p"), at: isoPrecise(t), kind: "window.changed", app: "Google Chrome", bundle: BrowserSafety.supportedBundle,
                        title: title, url: origin, synthetic: true, browserVerification: proof)
    }
    func unit(_ id: String, _ t: Date, surface: String, field: String, send: String, to: String? = nil) -> TypedUnitProvenance {
        var u = TypedUnitProvenance(runID: "run-" + id, part: 1, sealReason: send == "detected" ? "submit" : "idle", startedAt: iso(t.addingTimeInterval(-20)),
                                    keys: 60, edits: 2, withheld: 0)
        u.surface = surface; u.field = field; u.send = send; u.to = to; u.version = TypedUnitProvenance.sendFactsVersion
        return u
    }
    /// A typed row in a native app.
    func typedRow(_ t: Date, _ app: String, _ bundle: String, _ title: String, _ text: String, surface: String, field: String = "message",
                  send: String = "detected", to: String? = nil) -> Evidence {
        let id = nextID("t")
        var e = Evidence(id: id, at: iso(t), kind: "keyboard.text_input", app: app, bundle: bundle, title: title, text: text, synthetic: true)
        e.captureProvenance = NativeCaptureProvenance(policyRevision: "r", classifierVersion: "sensitive-typing/v2+typed-scrub/v1", windowID: "w-" + id,
                                                      focusID: "f-" + id, checkedAt: iso(t), generation: 1,
                                                      unit: unit(id, t, surface: surface, field: field, send: send, to: to))
        return e
    }
    /// A typed row on a website in Chrome, in the shape the owner build's Chrome join writes (`WebTypedRow`).
    func webTypedRow(_ t: Date, place: String, origin: String, _ text: String, surface: String, field: String = "textArea", send: String = "none") -> Evidence {
        let id = nextID("t")
        var proof = BrowserVerification(mode: "normal", windowID: "1520", tabID: "1733", focusedRole: "AXTextArea", checkedAt: iso(t), provider: "chrome-typing-join-v1")
        proof.documentID = "6F1C2B9A-0D3E-4C55-9B7A-1E2F3A4B5C6D"; proof.focusID = "0A1B2C3D-4E5F-4A6B-8C7D-9E0F1A2B3C4D"; proof.policyRevision = "policy-fixture"
        var e = Evidence(id: id, at: iso(t), kind: "keyboard.text_input", app: "Google Chrome", bundle: BrowserSafety.supportedBundle, title: place,
                         url: origin, text: text, synthetic: true, browserVerification: proof)
        e.captureProvenance = NativeCaptureProvenance(policyRevision: "policy-fixture", classifierVersion: UnitClassifier.version, windowID: "1520",
                                                      focusID: proof.focusID ?? "", checkedAt: iso(t), generation: 1,
                                                      unit: unit(id, t, surface: surface, field: field, send: send))
        return e
    }

    func add(_ e: Evidence) { rows.append(e) }
    /// Window rows every `every` seconds from `start` for `seconds`.
    func dwell(_ start: Date, seconds: Int, every: Int = 30, _ make: (Date, Int) -> Evidence) {
        var i = 0
        while i * every < seconds { add(make(start.addingTimeInterval(Double(i * every)), i)); i += 1 }
    }
    func noise(_ t: Date, _ app: String, _ bundle: String, _ title: String = "") {
        add(event(t, "app.activated", app, bundle, title))
        add(event(t.addingTimeInterval(2), "mouse.click", app, bundle, title))
        add(event(t.addingTimeInterval(4), "keyboard.shortcut", app, bundle, title))
    }

    static let chrome = BrowserSafety.supportedBundle
    static let docs = "https://docs.google.com", google = "https://www.google.com", x = "https://x.com", claudeAI = "https://claude.ai"
    static let messages = ("Messages", "com.apple.MobileSMS"), mail = ("Mail", "com.apple.mail"), terminal = ("Terminal", "com.apple.Terminal")
    static let claudeApp = ("Claude", "com.anthropic.claudefordesktop"), chatGPT = ("ChatGPT", "com.openai.chat")
    static let notes = ("Notes", "com.apple.Notes"), finder = ("Finder", "com.apple.finder")

    func writeWeek() throws {
        // MARK: Mon Sep 28: the 1,000-moment day
        let mon = Day.busy
        add(page(date(mon, 8, 30), Self.investorDoc + " - Google Docs", Self.docs))
        add(page(date(mon, 8, 50), Self.investorDoc + " - Google Docs", Self.docs))
        for (i, name) in Self.kestrelNames.prefix(40).enumerated() {
            add(window(date(mon, 9, i), Self.notes.0, Self.notes.1, "\(Self.searchWord) interview – \(name)"))
        }
        // Distinct windows, each its own short stop, alternating apps: a long, fragmented day of 1,000+ moments.
        let topics = ["ledger sync", "bank feed", "invoice export", "receipt match", "payroll import", "tax category", "vendor merge", "audit trail"]
        let pools: [(String, String, (Int) -> String)] = [
            (Self.terminal.0, Self.terminal.1, { "tallybird-api — vim — \(topics[$0 % 8]) \($0 / 8 + 1).swift" }),
            ("Xcode", "com.apple.dt.Xcode", { "TallybirdKit — \(topics[$0 % 8].capitalized)Tests\($0 / 8 + 1).swift" }),
            ("Preview", "com.apple.Preview", { "statement-\(topics[$0 % 8].replacingOccurrences(of: " ", with: "-"))-\($0 / 8 + 1).pdf" }),
            (Self.finder.0, Self.finder.1, { "fixtures \($0 / 8 + 1) \(topics[$0 % 8])" }),
        ]
        var t = date(mon, 10, 0)
        for i in 0..<Self.busyWindows {
            let pool = pools[i % pools.count]
            add(window(t, pool.0, pool.1, pool.2(i)))
            if i % 50 == 0 { add(event(t.addingTimeInterval(5), "mouse.click", pool.0, pool.1)) }
            t = t.addingTimeInterval(i % 3 == 0 ? 37 : 23)
        }
        counts["busyWindows"] = Self.busyWindows

        // MARK: Tue Sep 29: summaries-off day (no notes are written for it)
        let tue = Day.notesOff
        dwell(date(tue, 9, 15), seconds: 1_200) { at, _ in self.page(at, Self.hiringDoc + " - Google Docs", Self.docs) }
        add(window(date(tue, 9, 40), Self.messages.0, Self.messages.1, Self.sam))
        add(typedRow(date(tue, 9, 41), Self.messages.0, Self.messages.1, Self.sam, Self.hiringText, surface: "text", to: Self.sam))
        add(window(date(tue, 10, 5), Self.mail.0, Self.mail.1, "Welcome to Northwind Fellowship updates"))
        add(window(date(tue, 11, 0), Self.terminal.0, Self.terminal.1, Self.claudeCodeTitle, tool: "Claude Code"))
        add(window(date(tue, 11, 45), Self.terminal.0, Self.terminal.1, "~ — -zsh — 80×24"))
        noise(date(tue, 12, 0), Self.finder.0, Self.finder.1, "Downloads")

        // Wed Sep 30: empty. Fri Oct 2: empty.

        // MARK: Thu Oct 1
        let thu = Day.thursday
        dwell(date(thu, 9, 0), seconds: 120) { at, _ in self.page(at, Self.officeHoursForm + " - Google Forms", Self.docs) }
        dwell(date(thu, 9, 10), seconds: 900, every: 60) { at, _ in self.page(at, Self.draftDoc + " - Google Docs", Self.docs) }
        for (i, name) in Self.kestrelNames.dropFirst(40).enumerated() {
            add(window(date(thu, 10, i * 2), Self.notes.0, Self.notes.1, "\(Self.searchWord) interview – \(name)"))
        }
        add(page(date(thu, 11, 0), "", Self.claudeAI))
        add(webTypedRow(date(thu, 11, 1), place: "claude.ai", origin: Self.claudeAI,
                        "summarize what investors look for in a pre-seed bookkeeping startup", surface: "ai", field: "message", send: "detected"))
        add(window(date(thu, 13, 0), Self.messages.0, Self.messages.1, Self.sam))
        add(typedRow(date(thu, 13, 1), Self.messages.0, Self.messages.1, Self.sam, "office hours booked for next Tuesday at 3", surface: "text", to: Self.sam))
        add(event(date(thu, 13, 1, 30), "keyboard.submit", Self.messages.0, Self.messages.1, Self.sam))

        // MARK: Sat Oct 3 (yesterday, the standup day)
        let sat = Day.yesterday
        dwell(date(sat, 9, 30), seconds: 1_200, every: 60) { at, _ in self.page(at, Self.runwaySheet + " - Google Sheets", Self.docs) }
        for (h, m) in [(10, 0), (14, 20), (17, 40)] {
            dwell(date(sat, h, m), seconds: 300, every: 60) { at, _ in self.page(at, Self.pricingMemo + " - Google Docs", Self.docs) }
        }
        facts["pricingMemoLastOpen"] = "5:44 PM"
        counts["pricingMemoVisits"] = 3
        add(window(date(sat, 10, 30), Self.chatGPT.0, Self.chatGPT.1, "ChatGPT"))
        add(typedRow(date(sat, 10, 31), Self.chatGPT.0, Self.chatGPT.1, "ChatGPT", Self.chatGPTPrompt, surface: "ai"))
        add(window(date(sat, 11, 0), Self.mail.0, Self.mail.1, "Inbox (12 messages, 3 unread)"))
        add(window(date(sat, 11, 2), Self.mail.0, Self.mail.1, Self.mailSubjects[1]))
        add(window(date(sat, 11, 5), Self.mail.0, Self.mail.1, Self.mailSubjects[0]))
        add(typedRow(date(sat, 11, 7), Self.mail.0, Self.mail.1, Self.mailSubjects[0], Self.mailReply, surface: "email", field: "body", send: "unknown"))
        dwell(date(sat, 12, 0), seconds: 1_800, every: 60) { at, _ in self.window(at, Self.terminal.0, Self.terminal.1, Self.claudeCodeTitle, tool: "Claude Code") }
        add(typedRow(date(sat, 12, 2), Self.terminal.0, Self.terminal.1, Self.claudeCodeTitle, Self.terminalCommand, surface: "aiTool"))
        dwell(date(sat, 12, 35), seconds: 600, every: 60) { at, _ in self.window(at, Self.terminal.0, Self.terminal.1, Self.sshTitle) }
        add(window(date(sat, 12, 46), Self.terminal.0, Self.terminal.1, "~ — -zsh — 80×24"))
        add(window(date(sat, 13, 0), Self.messages.0, Self.messages.1, Self.jules))
        add(typedRow(date(sat, 13, 1), Self.messages.0, Self.messages.1, Self.jules, Self.textToJules, surface: "text", to: Self.jules))
        add(event(date(sat, 13, 1, 20), "keyboard.submit", Self.messages.0, Self.messages.1, Self.jules))
        add(typedRow(date(sat, 13, 3), Self.messages.0, Self.messages.1, Self.sam, Self.textWithCode, surface: "text", to: Self.sam))
        // A wordless search: the Google home page with no results row within 2 minutes ("searched on Google").
        add(page(date(sat, 14, 40), "Google", Self.google, tab: "1730"))
        facts["siteOnlySearch"] = "2:40 PM"
        add(page(date(sat, 15, 0), Self.searches[1], Self.google))
        add(page(date(sat, 15, 4), Self.searches[2], Self.google, tab: "1734"))
        add(page(date(sat, 15, 6), Self.article, Self.articleSite, tab: "1734"))
        dwell(date(sat, 16, 0), seconds: 1_200, every: 20) { at, i in self.page(at, i % 4 == 0 ? "(3) Home / X" : "Home / X", Self.x, tab: "1740") }
        noise(date(sat, 16, 30), Self.finder.0, Self.finder.1, "Tallybird")
        add(window(date(sat, 16, 31), Self.finder.0, Self.finder.1, "Tallybird"))

        // MARK: Sun Oct 4 (today)
        let sun = Day.today
        add(window(date(sun, 9, 0), Self.finder.0, Self.finder.1, "Downloads"))
        noise(date(sun, 9, 1), Self.finder.0, Self.finder.1, "Downloads")
        add(page(date(sun, 9, 5), Self.searches[0], Self.google))
        // The 60-minute feed: a row every 20 seconds, scrolls, a notification count flickering in the title.
        dwell(date(sun, 9, 10), seconds: 3_600, every: 20) { at, i in self.page(at, i % 5 == 0 ? "(2) Home / X" : "Home / X", Self.x, tab: "1750") }
        for i in stride(from: 0, to: 3_600, by: 120) { add(event(date(sun, 9, 10).addingTimeInterval(Double(i + 7)), "mouse.scroll", "Google Chrome", Self.chrome, "Home / X")) }
        counts["feedMinutes"] = 60
        dwell(date(sun, 10, 15), seconds: 1_500, every: 60) { at, _ in self.page(at, Self.draftDoc + " - Google Docs", Self.docs) }
        add(event(date(sun, 10, 21), "keyboard.submit", "Google Chrome", Self.chrome, Self.draftDoc + " - Google Docs"))
        // Google Docs typing isn't recorded (the website rules leave docs.google.com out), so the answers are written in
        // Notes first, as people do: typed rows there are kept in both lanes.
        add(window(date(sun, 10, 30), Self.notes.0, Self.notes.1, Self.answersNote))
        add(typedRow(date(sun, 10, 31), Self.notes.0, Self.notes.1, Self.answersNote, Self.draftTyping, surface: "writing", field: "textArea", send: "none"))
        add(window(date(sun, 10, 42), Self.claudeApp.0, Self.claudeApp.1, "Claude"))
        add(typedRow(date(sun, 10, 43), Self.claudeApp.0, Self.claudeApp.1, "Claude", Self.claudePrompt, surface: "ai"))
        // The 90-second form.
        dwell(date(sun, 10, 50), seconds: 90, every: 30) { at, _ in self.page(at, Self.form + " - Google Forms", Self.docs) }
        counts["formSeconds"] = 90
        add(window(date(sun, 10, 52), Self.messages.0, Self.messages.1, Self.sam))
        add(typedRow(date(sun, 10, 53), Self.messages.0, Self.messages.1, Self.sam, Self.textToSam, surface: "text", to: Self.sam))
        add(event(date(sun, 10, 53, 10), "keyboard.submit", Self.messages.0, Self.messages.1, Self.sam))
        add(event(date(sun, 10, 53, 12), "keyboard.submit", Self.messages.0, Self.messages.1, Self.sam))
        add(window(date(sun, 11, 30), Self.mail.0, Self.mail.1, Self.mailSubjects[2]))
        add(window(date(sun, 11, 33), Self.mail.0, Self.mail.1, Self.mailSubjects[0]))
        dwell(date(sun, 13, 0), seconds: 2_400, every: 60) { at, _ in self.window(at, Self.terminal.0, Self.terminal.1, Self.claudeCodeTitle, tool: "Claude Code") }
        add(typedRow(date(sun, 13, 5), Self.terminal.0, Self.terminal.1, Self.claudeCodeTitle, "add a test for the bank feed retry", surface: "aiTool"))
        dwell(date(sun, 13, 45), seconds: 300, every: 60) { at, _ in self.window(at, Self.terminal.0, Self.terminal.1, Self.sshTitle) }
        add(page(date(sun, 14, 10), "", Self.claudeAI, tab: "1760"))
        add(webTypedRow(date(sun, 14, 11), place: "claude.ai", origin: Self.claudeAI, Self.claudeWebPrompt, surface: "ai", field: "message", send: "detected"))
        add(window(date(sun, 15, 0), Self.notes.0, Self.notes.1, "Tallybird launch notes"))
        add(typedRow(date(sun, 15, 1), Self.notes.0, Self.notes.1, "Tallybird launch notes", Self.notesSecretsText, surface: "writing", field: "textArea", send: "none"))
        add(window(date(sun, 16, 30), Self.messages.0, Self.messages.1, Self.priya))
        add(typedRow(date(sun, 16, 31), Self.messages.0, Self.messages.1, Self.priya, Self.textToPriya, surface: "text", to: Self.priya))
        add(event(date(sun, 16, 31, 30), "keyboard.submit", Self.messages.0, Self.messages.1, Self.priya))
        add(window(date(sun, 16, 34), Self.messages.0, Self.messages.1, "Messages"))
        add(typedRow(date(sun, 16, 35), Self.messages.0, Self.messages.1, "Messages", Self.textToDana, surface: "text", to: Self.dana))
        add(event(date(sun, 16, 35, 20), "keyboard.submit", Self.messages.0, Self.messages.1, "Messages"))
        add(window(date(sun, 16, 40), "DayDream", "com.getnorthlight.daydream", "DayDream"))

        // Write in time order (the recorder's order).
        var kept = 0, refused = 0
        for e in rows.sorted(by: { ($0.at, $0.id) < ($1.at, $1.id) }) {
            let saved = try store.ingest(e, now: now)
            if e.kind == "keyboard.text_input" { if saved { typedKept.append(e.id) } else { typedRefused.append(e.id) } }
            if saved { kept += 1 } else { refused += 1 }
        }
        counts["rowsWritten"] = kept
        counts["rowsRefused"] = refused
        counts["kestrelItems"] = Self.kestrelNames.count
    }

    /// Notes on a few moments, including the kinds agents must never see: "In Terminal.", "Viewed Claude.", a line that
    /// only repeats the item's name, and a draft bullet.
    func writeNotes() throws {
        let plan: [(Day, String, [(String, String)])] = [
            (.today, Self.form, [("Viewed \(Self.form) - Google Forms.", "observed"), ("Filled in the company section of the Northwind application.", "observed")]),
            (.today, "tallybird-api", [("In Terminal.", "observed"), ("Worked on the bank feed retry with Claude Code.", "observed")]),
            (.today, "Claude", [("Viewed Claude.", "observed")]),
            (.today, Self.sam, [("Wrote to Sam about the Northwind draft.", "draft"), ("(draft) Asked Sam to review the traction answer.", "observed")]),
            (.yesterday, Self.pricingMemo, [("Updated the pilot price to 49 dollars per seat in the pricing memo.", "observed")]),
            (.yesterday, "ChatGPT", [("Viewed ChatGPT.", "observed")]),
            (.thursday, Self.officeHoursForm, [("Signed up for founder office hours.", "observed")]),
        ]
        var written = 0
        for (day, match, bullets) in plan {
            let moments = try store.dayLayers(day: day.rawValue, timezone: timezone, limit: 500, now: now).activities
            guard let moment = moments.first(where: { $0.subject.contains(match) || $0.apps.contains(match) }) else { continue }
            let request = try store.prepareNote(kind: "activity", day: day.rawValue, timezone: timezone, activityID: moment.id, now: now)
            let ids = request.actions.map(\.id)
            // A draft bullet cites the typed rows only (the store checks their state).
            let typedIDs = request.actions.filter { $0.kind == "keyboard.text_input" }.map(\.id)
            _ = try store.commitNote(NoteWriterOutput(requestID: request.id, title: moment.subject,
                                                      bullets: bullets.filter { $0.1 != "draft" || !typedIDs.isEmpty }
                                                        .map { NoteBullet(text: $0.0, actionIDs: $0.1 == "draft" ? typedIDs : ids, assertion: $0.1) },
                                                      generator: "local/synthetic", generatorVersion: "1"), now: now)
            written += 1
        }
        counts["notesWritten"] = written
    }

    public var manifest: AgentToolsFixtureManifest {
        var days: [String: String] = [:]
        for d in Day.allCases { days[String(describing: d)] = d.rawValue }
        var f = facts
        f["form"] = Self.form; f["officeHoursForm"] = Self.officeHoursForm; f["draftDoc"] = Self.draftDoc; f["pricingMemo"] = Self.pricingMemo
        f["searchWord"] = Self.searchWord; f["sam"] = Self.sam; f["priya"] = Self.priya; f["jules"] = Self.jules
        return AgentToolsFixtureManifest(timezone: timezone, now: iso(now), days: days, lane: Self.typingAppsOpen ? "owner" : "public",
                                         typedKept: typedKept, typedRefused: typedRefused, secrets: Self.secrets,
                                         secretNeighbours: Self.secretNeighbours, counts: counts, facts: f)
    }
    func writeManifest() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: home.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    /// The local actions of one fixture day (for model-level checks and WP detection).
    public func dayInput(_ day: Day) throws -> AgentDayInput {
        var actions: [CanonicalAction] = [], after: String? = nil
        repeat {
            let page = try store.dayLayers(day: day.rawValue, timezone: timezone, after: after, limit: 500, now: now).actions
            actions += page.actions; after = page.next
        } while after != nil
        return AgentDayInput(day: day.rawValue, timezone: timezone, actions: actions)
    }
}
