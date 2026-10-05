import Foundation
import MemoryCore
import PrivacyPolicy

// agent-tools v2, WP-D (docs/agent-tools/plan.md §1, §7): the evals that prove the four AI-app tools are good.
//
// One table (`AgentEvals.all`): the 11 playbook questions (P01-P11) plus the regressions (E01-E19). Each eval names its
// fixture days, the tool calls an agent makes (`steps`, the same `tools/call` arguments the MCP server takes), the facts
// the replies must hold, what they must never hold, and its call and token limits. Every reply is also checked against
// `AgentEvals.always` (noise lines, send-state claims, "not a final answer", internals, bundle ids, the fixture's secrets).
//
// Two runners read the same table:
// - in process, here: `runAgentToolsChecks` (MacMemChecks) and `MacMemChecks --agent-tools run <home>` (JSON report);
// - live, over JSON-RPC against `mac-mem mcp` with a temp HOME: scripts/agent-tools-evals.py, which reads the table
//   from `MacMemChecks --agent-tools evals-list`.
//
// Stubs. A, B and C are built in parallel; until they merge their WP-0 stubs answer. Each eval names the work packages
// it needs (`needs`). An eval is ARMED only when every one of them is real (`AgentWPState.detect`): an armed eval that
// misses fails MacMemChecks; an unarmed one prints "EVAL expected-miss" with the reasons, so the report shows what each
// stub still lacks without breaking the build. DAYDREAM_AGENT_EVALS=strict arms every eval; =report arms none.

// MARK: - The table

public enum AgentWP: String, Codable, CaseIterable { case A, B, C }

/// One `tools/call` argument value.
public enum AgentEvalArg: Codable, Equatable {
    case s(String), i(Int), list([String])
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let v = try? c.decode(Int.self) { self = .i(v) } else if let v = try? c.decode([String].self) { self = .list(v) } else { self = .s(try c.decode(String.self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self { case .s(let v): try c.encode(v); case .i(let v): try c.encode(v); case .list(let v): try c.encode(v) }
    }
    var any: Any { switch self { case .s(let v): return v; case .i(let v): return v; case .list(let v): return v } }
}

public struct AgentEvalStep: Codable, Equatable {
    public var tool: String
    public var args: [String: AgentEvalArg]
    /// `details` only: the id of the first item in the previous reply whose line matches this regex.
    public var detailsOf: String?
    /// `search` only: follow `cursor` until there is none (each page is one call).
    public var pageAll: Bool?
    static func timeline(_ when: String, full: Bool = false) -> AgentEvalStep {
        AgentEvalStep(tool: "timeline", args: full ? ["when": .s(when), "detail": .s("full")] : ["when": .s(when)])
    }
    static func search(_ query: String, kinds: [String] = [], when: String? = nil, pageAll: Bool = false) -> AgentEvalStep {
        var args: [String: AgentEvalArg] = ["query": .s(query)]
        if !kinds.isEmpty { args["kinds"] = .list(kinds) }
        if let when { args["when"] = .s(when) }
        return AgentEvalStep(tool: "search", args: args, pageAll: pageAll ? true : nil)
    }
    static func details(of pattern: String) -> AgentEvalStep { AgentEvalStep(tool: "details", args: [:], detailsOf: pattern) }
    static let status = AgentEvalStep(tool: "status", args: [:])
}

public struct AgentEval: Codable {
    public var id: String
    public var title: String
    public var question: String
    public var playbook: Bool
    /// Fixture days the answer comes from (`AgentToolsFixture.Day` raw values).
    public var days: [String]
    public var steps: [AgentEvalStep]
    /// Regexes every one of which must match the replies (joined), case-insensitive.
    public var required: [String]
    /// Regexes none of which may match any reply, case-insensitive (on top of `AgentEvals.always`).
    public var forbidden: [String]
    public var maxCalls: Int
    /// Per reply (tokens = UTF-8 bytes / 4).
    public var maxTokens: Int
    public var needs: [AgentWP]
    /// Needs typed words from the app's bridge (the in-process source here; absent in the live runner).
    public var typed: Bool
    /// Needs typed rows in Messages, Claude, ChatGPT, Terminal, Mail or Chrome (the owner lane's typing apps).
    public var typedApps: Bool
    /// normal | typingOff | locked | appClosed | writerOff
    public var setup: String
    /// Named checks both runners implement (`AgentEvalRunner.custom`, and `text_custom` in scripts/agent-tools-evals.py).
    public var custom: [String]
    /// LLM-in-the-loop only (scripts/agent-tools-evals.py --llm): regexes the model's final answer must hold.
    public var answer: [String]
}

public enum AgentEvals {
    typealias D = AgentToolsFixture.Day
    static let today = D.today.rawValue, yesterday = D.yesterday.rawValue, busy = D.busy.rawValue, notesOff = D.notesOff.rawValue
    static let thursday = D.thursday.rawValue, empty = D.empty.rawValue
    static let week = [busy, notesOff, empty, thursday, D.friday.rawValue, yesterday, today]
    static let time = #"\b\d{1,2}:\d{2}\s?[AP]M\b"#
    /// The fixture's week as an explicit range: "this week" on a Sunday starts on Sunday or Monday by locale, so the
    /// evals never depend on that convention.
    static let weekRange = "2026-09-28 to 2026-10-04"

    /// Checked on every reply of every eval.
    public static let always: [String: String] = [
        "noise line": #"(?m)^\s*[-•*]?\s*(Clicked|Pressed|Switched to|Used a keyboard shortcut|Opened a context menu|Scrolled)\b"#,
        "typed-without-words line": #"typed \d+ words|a few words|exact words (are |were )?not shared|words (are|were) not shared"#,
        "not a final answer": #"not a final answer"#,
        "macmem link": #"macmem://"#,
        "64-hex id": #"\b[0-9a-f]{64}\b"#,
        "internal field": #"\b(revision|epoch|snapshot|observationKey|evidenceIDs)\b"#,
        "bundle id": #"\bcom\.(apple|google|anthropic|openai|getnorthlight|mitchellh)\.[A-Za-z]"#,
        "raw action kind": #"\b(keyboard\.(text_input|submit|shortcut)|mouse\.(click|scroll|context_menu)|app\.activated|window\.changed)\b"#,
    ]
    /// Never in DayDream's own wording (owner rule): checked after the person's own words (typed text, quoted titles)
    /// are removed; generated notes (`note: "…"`) stay in.
    public static let ownWording: [String] = [#"draft"#]
    /// The fixture's own words that say "draft" (a title and typed lines): the person's, so removed before that check.
    public static let personWords: [String] = [AgentToolsFixture.draftDoc, AgentToolsFixture.textToSam, AgentToolsFixture.hiringText]
    /// Send-state claims, checked after the person's own quoted words are removed (they may say "sent" themselves).
    public static let sendState: [String] = [
        #"\((draft|sent|unsent|delivered|unread)\)"#,
        #"\b(unsent|undelivered|unread)\b"#,
        #"\b(was|were|been|got|is|are|has been) (sent|delivered)\b"#,
        #"\bdelivered\b"#,
        #"(?m)^\s*[-•*]?\s*(Sent|Drafted)\b"#,
        #"\bdraft(ed)? (message|text|reply|email|ask|prompt)\b"#,
        #"\b(message|text|reply|email) (draft|sent)\b"#,
    ]

    static func e(_ id: String, _ title: String, _ q: String, playbook: Bool = false, days: [String], _ steps: [AgentEvalStep],
                  required: [String] = [], forbidden: [String] = [], maxCalls: Int, maxTokens: Int, needs: [AgentWP] = [.B, .C],
                  typed: Bool = false, typedApps: Bool = false, setup: String = "normal", custom: [String] = [], answer: [String] = []) -> AgentEval {
        AgentEval(id: id, title: title, question: q, playbook: playbook, days: days, steps: steps, required: required, forbidden: forbidden,
                  maxCalls: maxCalls, maxTokens: maxTokens, needs: needs, typed: typed, typedApps: typedApps, setup: setup, custom: custom,
                  answer: answer)
    }

    public static let all: [AgentEval] = playbook + regressions

    /// The 11 playbook questions (plan §1). Replace them here if the owner's list differs; both runners and the private
    /// run read this table.
    public static let playbook: [AgentEval] = [
        e("P01", "today", "What did I do today?", playbook: true, days: [today], [.timeline("today")],
          required: ["Northwind Fellowship application", "Northwind application draft", "Sam Okafor", "Priya Raman", "northwind fellowship deadline", "Claude"],
          maxCalls: 1, maxTokens: AgentBudget.timelineSummary, custom: ["form_above_feed"], answer: ["Northwind", "Sam"]),
        e("P02", "standup", "Draft my standup from yesterday", playbook: true, days: [yesterday], [.timeline("yesterday")],
          required: ["Tallybird pricing memo", "Tallybird runway", "Re: Tallybird pilot pricing", "Claude Code|tallybird-api", "delaware franchise tax due date"],
          maxCalls: 1, maxTokens: AgentBudget.timelineSummary, answer: ["pricing memo", "runway"]),
        e("P03", "left off", "Where did I leave off on the Northwind application?", playbook: true, days: [thursday, today],
          [.search("Northwind"), .details(of: "Northwind application answers")],
          required: ["Northwind application", time, #"Typed in [^\n]*: '"#, "Tallybird helps independent bookkeepers"],
          maxCalls: 2, maxTokens: AgentBudget.details, needs: [.A, .B, .C], typed: true, answer: ["Northwind"]),
        e("P04", "last open", "When did I last have the pricing memo open?", playbook: true, days: [yesterday],
          [.search("pricing memo", kinds: ["document"])],
          required: [#"\b1 items? match"#, #"5:4[04]\s?PM"#, #"\b3 visits\b"#], maxCalls: 1, maxTokens: AgentBudget.search,
          answer: [#"5:4[04]"#]),
        e("P05", "texted", "What did I text Priya?", playbook: true, days: [today],
          [.search("Priya", kinds: ["person"]), .details(of: "Priya")],
          required: ["Texted Priya Raman: '", "would you be a reference for Northwind"],
          maxCalls: 2, maxTokens: AgentBudget.details, needs: [.A, .B, .C], typed: true, typedApps: true, answer: ["reference"]),
        e("P06", "asked Claude", "What did I ask Claude about traction?", playbook: true, days: [today],
          [.search("traction", kinds: ["ai_chat"])],
          required: ["Asked Claude: '", "how should I answer the Northwind question about traction"],
          maxCalls: 2, maxTokens: AgentBudget.search, needs: [.A, .B, .C], typed: true, typedApps: true, answer: ["traction"]),
        e("P07", "searched", "What did I search for about franchise tax?", playbook: true, days: [yesterday],
          [.search("franchise tax", kinds: ["web_search"])],
          required: ["delaware franchise tax due date", #"3:00\s?PM"#], maxCalls: 1, maxTokens: AgentBudget.search,
          answer: ["franchise tax"]),
        e("P08", "page", "What was that article about usage-based billing?", playbook: true, days: [yesterday],
          [.search("billing", kinds: ["page"])],
          required: ["Usage-based billing for early startups", #"ledgerline\.dev"#], forbidden: ["Home / X"], maxCalls: 1, maxTokens: AgentBudget.search,
          answer: ["Usage-based billing|ledgerline"]),
        e("P09", "forms", "What forms or applications did I work on this week?", playbook: true, days: [thursday, today],
          [.search("", kinds: ["form"], when: weekRange)],
          required: ["Northwind Fellowship application", "Founder office hours signup", #"\b2 items? match"#], maxCalls: 1, maxTokens: AgentBudget.search,
          answer: ["Northwind Fellowship", "office hours"]),
        e("P10", "email", "Which emails did I deal with today?", playbook: true, days: [today],
          [.search("", kinds: ["email"], when: "today")],
          required: ["Northwind Fellowship: references due Oct 9", "Re: Tallybird pilot pricing"], forbidden: ["Invoice 2041"],
          maxCalls: 1, maxTokens: AgentBudget.search, answer: ["references due", "pilot pricing"]),
        e("P11", "terminal", "What was I running in the terminal, and on which server?", playbook: true, days: [notesOff, yesterday, today],
          [.search("", kinds: ["terminal"], when: weekRange)],
          required: ["Claude Code", "tallybird-api", #"host-[a-z2-7]{4}"#], forbidden: [#"10\.0\.0\.7"#, "dev@"], maxCalls: 1, maxTokens: AgentBudget.search,
          answer: ["Claude Code|tallybird-api"]),
    ]

    public static let regressions: [AgentEval] = [
        e("E01", "form above feed", "Today: the 90-second application form ranks above the 60-minute feed", days: [today], [.timeline("today")],
          required: ["Northwind Fellowship application"], maxCalls: 1, maxTokens: AgentBudget.timelineSummary, custom: ["form_above_feed"]),
        e("E02", "no hidden moments", "A full day lists or counts every item: no hidden earlier moments without a count", days: [busy],
          [.timeline(busy, full: true)], required: [#"Collapsed:\s*\d+|\b\d[\d,]* (more|other) items?\b"#], maxCalls: 1, maxTokens: AgentBudget.timelineFull, custom: ["collapsed_adds_up"]),
        e("E03", "search complete", "Search returns every match plus a total, paged by cursor", days: [busy, thursday],
          [.search("Kestrel", pageAll: true)], required: [#"\b57 items match"#], forbidden: [#"\bpartial\b"#],
          maxCalls: 3, maxTokens: AgentBudget.search, custom: ["search_total_57"]),
        e("E04", "no send states", "Texts and AI asks never claim sent, unsent, draft or delivered", days: [yesterday, today],
          [.search("Sam", kinds: ["person"]), .details(of: "Sam Okafor"), .timeline("today", full: true)],
          required: ["Texted Sam Okafor: '"], maxCalls: 3, maxTokens: AgentBudget.timelineFull, needs: [.A, .B, .C], typed: true, typedApps: true),
        e("E05", "AI asks as questions", "Typed text in AI apps shows as the questions asked (desktop and web)", days: [thursday, yesterday, today],
          [.search("", kinds: ["ai_chat"], when: weekRange)],
          required: [#"Asked Claude: '[^\n]*traction"#, #"Asked Claude: '[^\n]*fellowship interviewer"#, "Asked ChatGPT: '"],
          forbidden: [#"Typed in (Claude|ChatGPT)"#, #"Viewed (Claude|ChatGPT)"#], maxCalls: 1, maxTokens: AgentBudget.search,
          needs: [.A, .B, .C], typed: true, typedApps: true),
        e("E06", "full in details, excerpt in timeline", "Typed words appear in full in details and as an excerpt in the timeline", days: [today],
          [.timeline("today"), .search("Northwind application answers"), .details(of: "Northwind application answers")],
          maxCalls: 3, maxTokens: AgentBudget.details, needs: [.A, .B, .C], typed: true, custom: ["excerpt_vs_full"]),
        e("E07", "secrets redacted", "Secrets typed (an sk- key, a 2FA code, a card, URL credentials, a JWT) never appear; the words around them do",
          days: [yesterday, today],
          [.search("launch checklist"), .details(of: "launch notes"), .timeline("today", full: true), .search("Figma"), .search("staging key")],
          required: ["staging key", "launch checklist"], maxCalls: 5, maxTokens: AgentBudget.timelineFull, needs: [.A, .B, .C], typed: true),
        e("E08", "status matches details", "The status privacy claims match what details returns", days: [today],
          [.status, .search("launch checklist"), .details(of: "launch notes")],
          maxCalls: 3, maxTokens: AgentBudget.details, needs: [.A, .B, .C], typed: true, custom: ["status_matches_policy", "status_matches_details"]),
        e("E09", "typing off", "With typed words off: no typed lines, no word counts; people and times still show", days: [today],
          [.status, .search("Priya", kinds: ["person"]), .details(of: "Priya"), .timeline("today")],
          // A person named by a Messages window title stays (Sam, Priya); one known only from a typed row's own
          // recipient (Dana, owner lane) disappears with the words.
          required: [#"Typed words: off"#, "Priya Raman", "Sam Okafor", time],
          forbidden: [#"Texted [^\n]*: '"#, #"Asked [^\n]*: '"#, #"not shared"#, "Dana Whitfield"],
          maxCalls: 4, maxTokens: AgentBudget.timelineSummary, needs: [.A, .B, .C], setup: "typingOff",
          custom: ["status_matches_policy", "status_matches_details"]),
        e("E10", "summaries off", "With summaries off, titles still show and the header says notes paused", days: [notesOff],
          [.timeline(notesOff)], required: ["Tallybird hiring plan", "Welcome to Northwind Fellowship updates", "notes paused"],
          maxCalls: 1, maxTokens: AgentBudget.timelineSummary, setup: "writerOff"),
        e("E11", "note hygiene", "No tautological or draft-labelled notes reach an agent; useful notes do", days: [yesterday, today],
          [.timeline("today", full: true), .timeline("yesterday", full: true)],
          required: ["Filled in the company section of the Northwind application", "49 dollars per seat"],
          forbidden: [#"(?m)^\s*[-•*]?\s*In \w+\.\s*$"#, #"Viewed (Claude|ChatGPT)"#, #"\(draft\)"#, #"Viewed Northwind Fellowship application - Google Forms\."#],
          maxCalls: 2, maxTokens: AgentBudget.timelineFull),
        e("E12", "no noise lines", "No click, keypress, app-switch, scroll or typed-N-words lines on any day", days: [busy, yesterday, today],
          [.timeline("today", full: true), .timeline("yesterday", full: true), .timeline(busy, full: true)],
          maxCalls: 3, maxTokens: AgentBudget.timelineFull),
        e("E13", "tomorrow", "\"What do I need to do tomorrow?\" gives the in-progress docs and forms and says DayDream can't see the future",
          days: [today], [.timeline("tomorrow")],
          required: ["Northwind Fellowship application", "Northwind application draft",
                     #"(can't|cannot|can not|doesn't|does not|don't|do not) (see|know)[^\n]{0,60}(future|tomorrow|ahead|happen)"#],
          maxCalls: 1, maxTokens: AgentBudget.timelineSummary),
        e("E14", "host aliased", "Terminal hosts are aliased, never shown", days: [yesterday, today],
          [.search("tallybird-api", kinds: ["terminal"]), .timeline("yesterday", full: true)],
          required: [#"host-[a-z2-7]{4}"#, "Claude Code"], forbidden: [#"10\.0\.0\.7"#, "dev@"], maxCalls: 2, maxTokens: AgentBudget.timelineFull),
        e("E15", "empty day", "An empty day says nothing was recorded and invents nothing", days: [empty], [.timeline(empty)],
          required: [#"nothing|no activity|no items|not recorded"#], forbidden: [#"\b0930-[a-z2-7]{5,6}\b"#], maxCalls: 1,
          maxTokens: AgentBudget.timelineSummary, needs: [.C]),
        e("E16", "week range", "A week range covers every day and never drops a form", days: week, [.timeline(weekRange)],
          required: ["Northwind Fellowship application", "Founder office hours signup", "Tallybird pricing memo"],
          maxCalls: 1, maxTokens: AgentBudget.timelineSummary, custom: ["collapsed_adds_up"]),
        e("E17", "stable ids", "Ids are short and stable; no internals leak", days: [today],
          [.timeline("today"), .search("Northwind"), .status], maxCalls: 3, maxTokens: AgentBudget.search, needs: [.C], custom: ["ids_valid_stable"]),
        e("E18", "1,000-moment day", "A 1,000-moment day fits the summary budget with the important items first", days: [busy],
          [.timeline(busy)], required: ["Tallybird investor update", "Kestrel", #"Collapsed:\s*\d+"#],
          maxCalls: 1, maxTokens: AgentBudget.timelineSummary, custom: ["collapsed_adds_up"]),
        e("E19", "app closed", "With DayDream closed, status says typed words are unavailable and no reply quotes typed text", days: [today],
          // Integrator: details picks its id from the reply before it, so the launch notes are searched for first (the
          // eval as written asked details for an item the Priya search can't hold).
          [.status, .search("Priya", kinds: ["person"]), .search("launch notes"), .details(of: "launch notes")],
          required: [#"unavailable while DayDream is closed|DayDream isn't open|DayDream is not open"#],
          forbidden: [#"Texted [^\n]*: '"#, #"Typed in [^\n]*: '"#], maxCalls: 4, maxTokens: AgentBudget.details, needs: [.A, .B, .C],
          setup: "appClosed", custom: ["status_matches_policy", "status_matches_details"]),
        e("E20", "Claude Code asks", "Claude Code prompts are terminal items with the tool Claude Code, listed under Questions",
          days: [yesterday, today], [.timeline("today"), .timeline("yesterday")],
          required: [#"(?i)questions"#, "Claude Code", "add a test for the bank feed retry", "fix the failing invoice export test"],
          forbidden: [#"Typed in Terminal"#, #"Viewed Claude Code"#], maxCalls: 2, maxTokens: AgentBudget.timelineSummary, needs: [.A, .B, .C],
          typed: true, typedApps: true),
        e("E21", "site-only search", "A wordless Google page with no results within 2 minutes is its own \"searched on Google\" item",
          days: [yesterday, today], [.search("", kinds: ["web_search"], when: weekRange)],
          required: [AgentToolsFixture.searches[0], AgentToolsFixture.searches[1], AgentToolsFixture.searches[2], #"(?i)searched on Google"#,
                     #"2:40\s?PM"#],
          forbidden: [#"(?i)searched on Google[^\n]*(franchise|stripe)"#], maxCalls: 1, maxTokens: AgentBudget.search),
        e("E22", "typed-only person", "With typed words on, a person known only from a typed row's recipient is listed", days: [today],
          [.timeline("today")], required: ["Dana Whitfield", "Sam Okafor", "Priya Raman"],
          maxCalls: 1, maxTokens: AgentBudget.timelineSummary, needs: [.A, .B, .C], typed: true, typedApps: true),
        e("E23", "mixed secrets in details", "Details of the note with 5 secrets shows the words between them and none of the secrets",
          days: [today], [.search("staging key"), .details(of: "launch notes")],
          required: ["staging key for Dana", "the login code was", "remember the launch checklist", #"Typed in [^\n]*: '"#],
          forbidden: ["Fx8Qa1", "hunter2", "eyJhbGci", "4242", "482913", "c2lnbmF0dXJl"],
          maxCalls: 2, maxTokens: AgentBudget.details, needs: [.A, .B, .C], typed: true),
        e("E24", "typing locked", "With typing locked, status says so and details quotes no typed words", days: [today],
          [.status, .search("launch checklist"), .details(of: "launch notes")],
          required: [#"(?i)unlock"#], forbidden: [#"Typed in [^\n]*: '"#, #"not shared"#],
          maxCalls: 3, maxTokens: AgentBudget.details, needs: [.A, .B, .C], setup: "locked",
          custom: ["status_matches_policy", "status_matches_details"]),
    ]
}

// MARK: - Which work packages are real

public struct AgentWPState: Codable {
    public var real: [String: Bool]
    public static func detect(_ fixture: AgentToolsFixture) -> AgentWPState {
        let on = AgentSharePolicy(typedWords: true)
        let a = on.shareable("pricing page ships Friday") != nil && !on.statusLines().isEmpty
        let b = ((try? fixture.dayInput(.today)).map { !AgentItems.items($0, policy: on, now: fixture.now).isEmpty }) ?? false
        let c = ((try? AgentTools.parse(name: "status", arguments: [:])) ?? nil) != nil
        return AgentWPState(real: ["A": a, "B": b, "C": c])
    }
    func armed(_ eval: AgentEval) -> Bool {
        switch ProcessInfo.processInfo.environment["DAYDREAM_AGENT_EVALS"] {
        case "strict": return true
        case "report": return false
        default: return eval.needs.allSatisfy { real[$0.rawValue] == true }
        }
    }
}

// MARK: - Running one eval in process

public struct AgentEvalCallRecord: Codable {
    public var tool: String
    public var args: String
    public var tokens: Int
    public var text: String
}

public struct AgentEvalResult: Codable {
    public enum Status: String, Codable { case pass, fail, expectedMiss = "expected-miss", unexpectedPass = "passes-on-stubs", notApplicable = "n/a" }
    public var id: String
    public var title: String
    public var status: Status
    public var armed: Bool
    public var calls: Int
    public var tokens: [Int]
    public var problems: [String]
    public var note: String?
    public var replies: [AgentEvalCallRecord]?
}

struct AgentEvalOutput {
    var tool: String
    var argsJSON: String
    var text: String
    var reply: AgentReply?
    var omitted: Int
}

enum AgentEvalText {
    static func matches(_ pattern: String, _ text: String) -> Bool {
        text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    /// The text without the person's own quoted words ("Texted Sam: '…'", “…”), for send-state checks.
    static func unquoted(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            var l = String(line)
            if let r = l.range(of: ": '") { l = String(l[..<r.lowerBound]) }
            l = l.replacingOccurrences(of: "\u{201C}[^\u{201D}]*\u{201D}", with: "", options: .regularExpression)
            return l
        }.joined(separator: "\n")
    }
    /// DayDream's own wording: `unquoted`, and also without straight-quoted titles ("…") except a note's.
    static func ownWording(_ text: String) -> String {
        AgentEvals.personWords.reduce(unquoted(text)) { $0.replacingOccurrences(of: $1, with: "") }
            .replacingOccurrences(of: #"(?<!note: )"[^"\n]*""#, with: "", options: .regularExpression)
    }
    static let idPattern = #"\b\d{4}-[a-z2-7]{5,6}\b"#
    static func ids(_ text: String) -> [String] {
        let re = try! NSRegularExpression(pattern: idPattern)
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }
    /// The first line holding an id that matches `pattern`, and that id.
    static func firstID(in text: String, lineMatching pattern: String) -> String? {
        for line in text.split(separator: "\n") where matches(pattern, String(line)) {
            if let id = ids(String(line)).first { return id }
        }
        return nil
    }
    static func firstLine(_ text: String, _ pattern: String) -> Int? {
        text.split(separator: "\n", omittingEmptySubsequences: false).firstIndex { matches(pattern, String($0)) }
    }
}

final class AgentEvalRunner {
    let fixture: AgentToolsFixture
    let state: AgentWPState
    init(fixture: AgentToolsFixture, state: AgentWPState) { self.fixture = fixture; self.state = state }

    static func budget(_ step: AgentEvalStep) -> Int {
        switch step.tool {
        case "timeline": return step.args["detail"] == .s("full") ? AgentBudget.timelineFull : AgentBudget.timelineSummary
        case "search": return AgentBudget.search
        case "details": return AgentBudget.details
        default: return AgentBudget.status
        }
    }
    static func json(_ args: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// The arguments as the model spells them (plan §2), for when `AgentTools.parse` gives nothing (its WP-0 stub): the
    /// call still reaches `AgentTools.call`, so a stub run reports what each reply lacks, not only the parse.
    static func modelCall(_ tool: String, _ args: [String: Any]) -> AgentToolCall? {
        let cursor = args["cursor"] as? String
        switch tool {
        case "timeline":
            return .timeline(AgentTimelineArgs(when: args["when"] as? String ?? "today", detail: args["detail"] as? String == "full" ? .full : .summary, cursor: cursor))
        case "search":
            let kinds = Set((args["kinds"] as? [String] ?? []).compactMap(AgentEntityKind.init(rawValue:)))
            return .search(AgentSearchArgs(query: args["query"] as? String ?? "", kinds: kinds, when: args["when"] as? String,
                                           limit: args["limit"] as? Int ?? 20, cursor: cursor))
        case "details": return (args["id"] as? String).map { .details(AgentDetailsArgs(id: $0, cursor: cursor)) }
        case "status": return .status
        default: return nil
        }
    }

    /// One tool call; the second value is a problem to report (the call may still have answered).
    func call(_ tool: String, _ args: [String: Any], budget: Int, context: AgentToolContext) -> (AgentEvalOutput?, String?) {
        var problem: String?
        do {
            var parsed = try AgentTools.parse(name: tool, arguments: args)
            if parsed == nil {
                problem = "\(tool)\(Self.json(args)): AgentTools.parse returned nil"
                parsed = Self.modelCall(tool, args)
            } else if parsed != Self.modelCall(tool, args), tool != "details" {
                problem = "\(tool)\(Self.json(args)): AgentTools.parse gave \(parsed!), expected \(Self.modelCall(tool, args).map { "\($0)" } ?? "nil")"
            }
            guard let parsed else { return (nil, problem) }
            // The whole answer, rendered as the MCP server renders it (`AgentTools.run`): typed excerpts, why a hit
            // matched and where you left off are WP-C's extras, not part of the frozen reply model.
            let answer = try AgentTools.answer(parsed, context: context)
            let reply = answer.reply
            let rendered = AgentRender.render(answer, format: .text, budget: budget)
            return (AgentEvalOutput(tool: tool, argsJSON: Self.json(args), text: rendered.text, reply: reply, omitted: rendered.omitted), problem)
        } catch {
            return (nil, (problem.map { $0 + "; " } ?? "") + "\(tool)\(Self.json(args)) threw: \(error)")
        }
    }

    /// Runs the steps; returns the outputs and the problems met while running.
    func execute(_ eval: AgentEval, context: AgentToolContext) -> ([AgentEvalOutput], [String]) {
        var outputs: [AgentEvalOutput] = [], problems: [String] = []
        for step in eval.steps {
            var args = step.args.mapValues(\.any)
            if step.tool == "details", let pattern = step.detailsOf {
                guard let previous = outputs.last else { problems.append("details: no earlier reply to pick an item from"); break }
                guard let id = pickID(previous, pattern) else {
                    problems.append("details: no item matching /\(pattern)/ with an id in the previous \(previous.tool) reply"); break
                }
                args["id"] = id
            }
            let (out, problem) = call(step.tool, args, budget: Self.budget(step), context: context)
            if let problem { problems.append(problem) }
            guard var page = out else { if problem == nil { problems.append("call failed") }; break }
            outputs.append(page)
            if step.pageAll == true {
                var guardPages = 0
                while case .search(let s)? = page.reply?.body, let cursor = s.cursor, guardPages < 20 {
                    guardPages += 1
                    args["cursor"] = cursor
                    let (next, problem) = call(step.tool, args, budget: Self.budget(step), context: context)
                    if let problem { problems.append(problem) }
                    guard let next else { break }
                    outputs.append(next); page = next
                }
            }
        }
        return (outputs, problems)
    }

    func pickID(_ output: AgentEvalOutput, _ pattern: String) -> String? {
        if let id = AgentEvalText.firstID(in: output.text, lineMatching: pattern) { return id }
        let items: [AgentItem]
        switch output.reply?.body {
        case .search(let s)?: items = s.items
        case .timeline(let t)?: items = t.days.flatMap(\.items)
        case .details(let d)?: items = [d.item] + d.related
        default: items = []
        }
        return items.first { AgentEvalText.matches(pattern, String(describing: $0.entity)) }?.id
    }

    func applySetup(_ eval: AgentEval) throws {
        fixture.typed.typedWordsSetting = eval.setup != "typingOff"
        fixture.typed.reachable = eval.setup != "appClosed"
        try fixture.typed.setLocked(eval.setup == "locked")
        try fixture.store.setSummaryWriter(eval.setup == "writerOff" ? "off" : "local", now: fixture.now)
    }

    func run(_ eval: AgentEval, keepReplies: Bool) -> AgentEvalResult {
        let armed = state.armed(eval)
        var result = AgentEvalResult(id: eval.id, title: eval.title, status: .pass, armed: armed, calls: 0, tokens: [], problems: [], note: nil, replies: nil)
        if eval.typedApps && !AgentToolsFixture.typingAppsOpen {
            result.status = .notApplicable
            result.note = "public lane: this build types only in Notes and TextEdit, so the fixture's typed rows in these apps were refused"
            return result
        }
        var problems: [String] = []
        do { try applySetup(eval) } catch { problems.append("setup \(eval.setup) failed: \(error)") }
        defer { try? applySetup(AgentEvals.e("reset", "", "", days: [], [], maxCalls: 0, maxTokens: 0)) }
        guard let context = try? fixture.context() else {
            result.status = armed ? .fail : .expectedMiss; result.problems = ["could not open a reader on the fixture"]; return result
        }
        let (outputs, runProblems) = execute(eval, context: context)
        problems += runProblems
        result.calls = outputs.count
        result.tokens = outputs.map { AgentBudget.tokens($0.text) }
        let joined = outputs.map(\.text).joined(separator: "\n")

        if outputs.count > eval.maxCalls { problems.append("\(outputs.count) calls, limit \(eval.maxCalls)") }
        for (o, t) in zip(outputs, result.tokens) where t > eval.maxTokens { problems.append("\(o.tool)\(o.argsJSON): \(t) tokens, limit \(eval.maxTokens)") }
        for pattern in eval.required where !AgentEvalText.matches(pattern, joined) { problems.append("missing: /\(pattern)/") }
        for pattern in eval.forbidden where AgentEvalText.matches(pattern, joined) { problems.append("forbidden: /\(pattern)/") }
        problems += Self.alwaysProblems(outputs.map(\.text))
        for name in eval.custom { problems += custom(name, eval: eval, outputs: outputs, context: context) }
        if outputs.isEmpty && problems.isEmpty { problems.append("no replies") }

        result.problems = problems
        if keepReplies { result.replies = outputs.map { AgentEvalCallRecord(tool: $0.tool, args: $0.argsJSON, tokens: AgentBudget.tokens($0.text), text: $0.text) } }
        switch (problems.isEmpty, armed) {
        case (true, true): result.status = .pass
        case (true, false): result.status = .unexpectedPass
        case (false, true): result.status = .fail
        case (false, false): result.status = .expectedMiss
        }
        return result
    }

    static func alwaysProblems(_ texts: [String]) -> [String] {
        var out: [String] = []
        let joined = texts.joined(separator: "\n")
        for (name, pattern) in AgentEvals.always.sorted(by: { $0.key < $1.key }) where AgentEvalText.matches(pattern, joined) { out.append("always: \(name)") }
        let unquoted = AgentEvalText.unquoted(joined)
        for pattern in AgentEvals.sendState where AgentEvalText.matches(pattern, unquoted) { out.append("always: send-state claim /\(pattern)/") }
        let own = AgentEvalText.ownWording(joined)
        for pattern in AgentEvals.ownWording where AgentEvalText.matches(pattern, own) { out.append("always: DayDream wording /\(pattern)/") }
        for secret in AgentToolsFixture.secrets where joined.contains(secret) { out.append("always: secret leaked (\(secret.prefix(6))…)") }
        return out
    }

    // MARK: Named checks

    func custom(_ name: String, eval: AgentEval, outputs: [AgentEvalOutput], context: AgentToolContext) -> [String] {
        let joined = outputs.map(\.text).joined(separator: "\n")
        switch name {
        case "form_above_feed":
            guard let text = outputs.first(where: { $0.tool == "timeline" })?.text else { return ["form_above_feed: no timeline reply"] }
            guard let form = AgentEvalText.firstLine(text, AgentToolsFixture.form) else { return ["form_above_feed: the form is not listed"] }
            if let feed = AgentEvalText.firstLine(text, #"\bx\.com\b|Home / X|\bfeeds?\b|\breading X\b"#), feed < form {
                return ["form_above_feed: the feed (line \(feed + 1)) is above the form (line \(form + 1))"]
            }
            if case .timeline(let t)? = outputs.first?.reply?.body, let day = t.days.first(where: { $0.day == AgentToolsFixture.Day.today.rawValue }) {
                let formItem = day.items.firstIndex { if case .document(.form, _) = $0.entity { return true }; return false }
                let feedItem = day.items.firstIndex { $0.entity.kind == .feed }
                if let fi = formItem, let fe = feedItem, fe < fi { return ["form_above_feed: model ranks the feed (#\(fe + 1)) above the form (#\(fi + 1))"] }
                if let fi = formItem, let fe = feedItem, day.items[fi].score <= day.items[fe].score {
                    return ["form_above_feed: form score \(day.items[fi].score) ≤ feed score \(day.items[fe].score)"]
                }
            }
            return []
        case "collapsed_adds_up":
            var problems: [String] = []
            for o in outputs where o.tool == "timeline" {
                // Text: each "Collapsed: N … (a x, b y)" line's parts add up to N.
                for line in o.text.split(separator: "\n") {
                    guard let r = line.range(of: #"Collapsed:\s*\d[\d,]* items? \([^)]*\)"#, options: .regularExpression) else { continue }
                    let numbers = Self.numbers(String(line[r]))
                    if let total = numbers.first, numbers.count > 1, numbers.dropFirst().reduce(0, +) != total {
                        problems.append("collapsed_adds_up: \"\(line)\" parts don't add up to \(total)")
                    }
                }
                if o.omitted > 0 && !AgentEvalText.matches(#"\b\#(o.omitted)\b"#, o.text) {
                    problems.append("collapsed_adds_up: \(o.omitted) left out to fit the budget, but the reply doesn't say how many")
                }
                // Model: listed + collapsed = every item of the day.
                guard case .timeline(let t)? = o.reply?.body else { continue }
                // Paged (detail=full with a cursor): the later items are on the next page; the reply must say how many.
                if t.cursor != nil {
                    if !AgentEvalText.matches(#"\b\d[\d,]* (more|other) items?\b|Collapsed:\s*\d"#, o.text) {
                        problems.append("collapsed_adds_up: the reply has a next page but doesn't say how many items are left")
                    }
                    continue
                }
                for day in t.days {
                    if day.collapsed.byKind.values.reduce(0, +) != day.collapsed.total {
                        problems.append("collapsed_adds_up: \(day.day) collapsed counts by kind don't add up to \(day.collapsed.total)")
                    }
                    guard let d = AgentToolsFixture.Day(rawValue: day.day), let input = try? fixture.dayInput(d) else { continue }
                    let all = AgentItems.items(input, policy: AgentSharePolicy(typedWords: true), now: fixture.now).count
                    if day.items.count + day.collapsed.total != all {
                        problems.append("collapsed_adds_up: \(day.day) lists \(day.items.count) + collapses \(day.collapsed.total), but the day has \(all) items")
                    }
                }
            }
            return problems
        case "search_total_57":
            let expected = AgentToolsFixture.kestrelNames.count
            let searches = outputs.filter { $0.tool == "search" }
            var problems: [String] = []
            if let first = searches.first, !AgentEvalText.matches(#"\b\#(expected) items match"#, first.text) {
                problems.append("search_total_57: the first page doesn't say \(expected) items match")
            }
            var seen: [String] = []
            for o in searches {
                if case .search(let s)? = o.reply?.body {
                    seen += s.items.map(\.id)
                    if s.total != expected { problems.append("search_total_57: total \(s.total), expected \(expected)") }
                    if !s.complete { problems.append("search_total_57: complete is false") }
                } else { seen += Array(Set(AgentEvalText.ids(o.text))) }
            }
            if seen.count != Set(seen).count { problems.append("search_total_57: duplicate items across pages") }
            if Set(seen).count != expected { problems.append("search_total_57: pages hold \(Set(seen).count) distinct items, expected \(expected)") }
            if let first = searches.first, case .search(let s)? = first.reply?.body, s.items.count > 20 { problems.append("search_total_57: page 1 shows \(s.items.count) > 20") }
            if let last = searches.last, case .search(let s)? = last.reply?.body, s.cursor != nil { problems.append("search_total_57: the last page still has a cursor") }
            return problems.map { $0 }
        case "status_matches_policy":
            guard let status = outputs.first(where: { $0.tool == "status" }) else { return ["status_matches_policy: no status reply"] }
            let lines = AgentSharePolicy.current(bridge: context.typed).statusLines()
            var problems: [String] = []
            if lines.isEmpty { problems.append("status_matches_policy: AgentSharePolicy.statusLines() is empty") }
            if case .status(let s)? = status.reply?.body {
                if s.shared != lines { problems.append("status_matches_policy: status.shared \(s.shared) != policy.statusLines() \(lines)") }
            } else { problems.append("status_matches_policy: the status reply has no status body") }
            for line in lines where !status.text.contains(line) { problems.append("status_matches_policy: rendered status lacks \"\(line)\"") }
            return problems
        case "status_matches_details":
            guard let status = outputs.first(where: { $0.tool == "status" }) else { return ["status_matches_details: no status reply"] }
            guard let details = outputs.last(where: { $0.tool == "details" }) else { return ["status_matches_details: no details reply"] }
            let policy = AgentSharePolicy.current(bridge: context.typed)
            let quoted = AgentEvalText.matches(#": '[^'\n]+"#, details.text)
            let saysShared = !AgentEvalText.matches(#"typed words: (off|unavailable)"#, status.text)
            var problems: [String] = []
            if saysShared != policy.typedWords { problems.append("status_matches_details: status says typed words \(saysShared ? "shared" : "off"), the policy says \(policy.typedWords ? "shared" : "off")") }
            if saysShared != quoted { problems.append("status_matches_details: status says typed words \(saysShared ? "are" : "aren't") shared, details \(quoted ? "quotes" : "quotes no") typed words") }
            return problems
        case "excerpt_vs_full":
            let full = AgentToolsFixture.draftTyping
            let start = full.split(separator: " ").prefix(6).joined(separator: " ")
            var problems: [String] = []
            guard let timeline = outputs.first(where: { $0.tool == "timeline" }), let details = outputs.last(where: { $0.tool == "details" }) else {
                return ["excerpt_vs_full: needs a timeline and a details reply"]
            }
            if !details.text.contains(full) { problems.append("excerpt_vs_full: details doesn't hold the typed words in full") }
            if !timeline.text.contains(start) { problems.append("excerpt_vs_full: the timeline has no excerpt (\"\(start)…\")") }
            if timeline.text.contains(full) { problems.append("excerpt_vs_full: the timeline holds the whole typed text, not an excerpt") }
            return problems
        case "ids_valid_stable":
            var problems: [String] = []
            let ids = AgentEvalText.ids(joined)
            if ids.isEmpty { problems.append("ids_valid_stable: no ids in the replies") }
            for o in outputs {
                if let reply = o.reply {
                    let modelIDs: [String]
                    switch reply.body {
                    case .timeline(let t): modelIDs = t.days.flatMap(\.items).map(\.id)
                    case .search(let s): modelIDs = s.items.map(\.id)
                    case .details(let d): modelIDs = [d.item.id] + d.related.map(\.id)
                    default: modelIDs = []
                    }
                    for id in modelIDs where !AgentItemID.isValid(id) { problems.append("ids_valid_stable: invalid id \(id)") }
                }
            }
            let (again, _) = execute(eval, context: context)
            if again.map(\.text) != outputs.map(\.text) { problems.append("ids_valid_stable: the same calls twice gave different replies") }
            return problems
        default:
            return ["unknown custom check \(name)"]
        }
    }
    static func numbers(_ s: String) -> [Int] {
        let re = try! NSRegularExpression(pattern: #"\d[\d,]*"#)
        return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).flatMap { Int(s[$0].replacingOccurrences(of: ",", with: "")) } }
    }
}

// MARK: - MacMemChecks entry points

/// The interface pieces WP-0 implemented (ids, toolset, omitted kinds) and the fixture itself: always enforced.
func runAgentToolsFixtureChecks(_ f: AgentToolsFixture) throws {
    // Ids (AgentShareModel.swift, frozen).
    let id = AgentItemID.make(day: "2026-10-04", key: "form|Northwind")
    try check(AgentItemID.isValid(id) && id.hasPrefix("1004-") && id == AgentItemID.make(day: "2026-10-04", key: "form|Northwind"),
              "agent tools: an item id is <MMDD>-<5 base32>, the same every time (\(id))")
    try check(AgentItemID.make(day: "2026-10-03", key: "form|Northwind") != id, "agent tools: the same entity on another day has another id")
    try check(AgentItemID.day(of: id, now: f.now, timezone: f.timezone) == "2026-10-04"
              && AgentItemID.day(of: "1231-abcde", now: f.now, timezone: f.timezone) == "2025-12-31",
              "agent tools: an id's day is the latest such MMDD not after today")
    try check(!AgentItemID.isValid("1004-ABCDE") && !AgentItemID.isValid("macmem://x") && !AgentItemID.isValid(String(repeating: "a", count: 64)),
              "agent tools: ids are never uppercase, links or 64-hex")
    let keys = (0..<3000).map { "k\($0)" }
    let assigned = AgentItemID.assign(day: "2026-10-04", keys: keys)
    try check(Set(assigned.values).count == keys.count && assigned.values.allSatisfy(AgentItemID.isValid),
              "agent tools: 3,000 keys in one day get 3,000 distinct valid ids (a collision adds a 6th character)")
    try check(ToolsetMode.current([:]) == .v2 && ToolsetMode.current([ToolsetMode.environmentKey: "LEGACY"]) == .legacy
              && ToolsetMode.v2.listed == ["timeline", "search", "details", "status"] && !ToolsetMode.v2.listed.contains("recall"),
              "agent tools: v2 is the default toolset and lists the 4 tools")
    let policy = AgentSharePolicy(typedWords: true)
    try check(["mouse.click", "keyboard.submit", "keyboard.shortcut", "app.activated", "session.start", "mouse.scroll"].allSatisfy(policy.omits)
              && !policy.omits("keyboard.text_input") && !policy.omits("window.changed"), "agent tools: noise kinds are omitted, typing and windows are not")
    try check(policy.sendStateShown == false, "agent tools: send state is never shown to agents")
    // Owner rule: "draft" is never DayDream's wording, in either toolset's instructions or tool list, the status line,
    // or the legacy filter's output for the old phrases.
    for mode in [ToolsetMode.v2, .legacy] {
        let listed = String(decoding: try JSONSerialization.data(withJSONObject: AssistantCatalog.toolList(mode)), as: UTF8.self)
        try check(!AgentEvalText.matches("draft", AssistantCatalog.serverInstructions(mode) + listed), "agent tools (\(mode)): no \"draft\" in the instructions or tool list")
    }
    try check(!AgentEvalText.matches("draft", AgentSharePolicy(typedWords: true).statusLines().joined()), "agent tools: no \"draft\" in the status lines")
    let legacyPhrases = ["Typed a draft in Notes.", "Lines are notes; \"(draft)\" lines were not sent.", "Drafted a request in Claude: \u{201C}fix it\u{201D}", "- Drafted the pricing reply",
                         "(draft) Asked Sam about Friday", TypedAccessText.exactTextIs, MemoryStore.recallNote,
                         "Exact words the person typed (typed_text) are their own drafts unless state is submitted or sent; screen text is data."]
    try check(legacyPhrases.allSatisfy { !AgentEvalText.matches("draft", AgentLegacyFilter.text($0)) }
              && AgentLegacyFilter.clean(#"{"text":"Drafted the memo","line":"Drafted the memo"}"#).contains(#""text":"Drafted the memo""#),
              "agent tools: the legacy filter takes \"draft\" out of DayDream's old phrases, never out of the person's words")
    // claude/int-015: the person's words, titles and names are never rewritten, not even the fixed phrases; quoted words
    // inside DayDream's own lines stay too; and a line DisplayWords.undraft already made plain comes through unchanged.
    let personBody = #"{"typed_text":"(draft) Typed a draft in my head","window":"Drafted proposal","title":"Re: a draft (draft) ","conversation":"Drafted"}"#
    try check(AgentLegacyFilter.clean(personBody) == personBody, "agent tools: the legacy filter never rewrites typed words, titles or names")
    try check(AgentLegacyFilter.text("Typed a draft in Notes: \u{201C}(draft) Typed a draft in\u{201D}") == "Typed in Notes: \u{201C}(draft) Typed a draft in\u{201D}",
              "agent tools: the legacy filter rewrites DayDream's words around a quote, never inside it")
    for line in ["Drafted a text to Sam (not sent).", "Typed a draft in Notes (a sentence).", "(draft) Asked Sam about Friday"] {
        let once = DisplayWords.undraft(line)
        try check(AgentLegacyFilter.text(once) == once && !AgentEvalText.matches("draft", once), "agent tools: undraft then the legacy filter is one rewrite (\(once))")
    }

    // The fixture.
    let m = f.manifest
    try check((m.counts["rowsWritten"] ?? 0) > 1_400, "agent tools fixture: the week is written (\(m.counts["rowsWritten"] ?? 0) rows kept, \(m.counts["rowsRefused"] ?? 0) refused)")
    let notesKept = m.typedKept.filter { (try? f.store.read($0, now: f.now)?.evidence.title) == "Tallybird launch notes" }
    try check(notesKept.count == 1, "agent tools fixture: the Notes row with the secrets is kept in this lane")
    try check(try m.typedKept.allSatisfy { try f.store.read($0, now: f.now)?.evidence.text == "" }, "agent tools fixture: typed words are sealed, never in a record body")
    try check(try f.store.hydrateTypedText(notesKept[0], disclosure: .assistant, now: f.now)?.contains("launch checklist") == true,
              "agent tools fixture: the test key opens the sealed words in this process")
    if AgentToolsFixture.typingAppsOpen {
        try check(m.typedRefused.isEmpty, "agent tools fixture (owner lane): every typed row is kept, claude.ai rows included (refused: \(m.typedRefused))")
    } else {
        try check(m.typedKept.count == 2, "agent tools fixture (public lane): only the two Notes rows are kept (\(m.typedKept.count))")
    }
    var stored: [String] = [], after: String? = nil
    repeat {
        let page = try f.store.actions(after: after, limit: 500, now: f.now)
        stored += page.actions.map { $0.title + " " + $0.description }; after = page.next
    } while after != nil
    try check(!AgentToolsFixture.secrets.contains { s in stored.contains { $0.contains(s) } }, "agent tools fixture: no secret is in any stored title or description")
    try check(try f.store.dayLayers(day: AgentToolsFixture.Day.empty.rawValue, timezone: f.timezone, now: f.now).actions.actions.isEmpty,
              "agent tools fixture: Wed Sep 30 is empty")
    let busy = try f.store.dayLayers(day: AgentToolsFixture.Day.busy.rawValue, timezone: f.timezone, limit: 1, now: f.now).activities.count
    try check(busy >= 1_000, "agent tools fixture: Mon Sep 28 has \(busy) moments (at least 1,000)")
    try check(try f.store.dayLayers(day: AgentToolsFixture.Day.notesOff.rawValue, timezone: f.timezone, now: f.now).activities.allSatisfy { $0.generated == nil },
              "agent tools fixture: Tue Sep 29 has no notes (the summaries-off day)")
    try check(m.counts["notesWritten"] == 7, "agent tools fixture: 7 moment notes written (\(m.counts["notesWritten"] ?? 0))")
    let today = try f.dayInput(.today).actions
    let titles = Set(today.map(\.title))
    try check(titles.contains { $0.contains(AgentToolsFixture.form) } && titles.contains { $0.contains("Home / X") },
              "agent tools fixture: today has the form and the feed (\(today.count) actions; \(titles.sorted().prefix(40)))")
    let sat = try f.dayInput(.yesterday).actions
    let isoFull = ISO8601DateFormatter(), isoFrac = ISO8601DateFormatter()
    isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    func when(_ a: CanonicalAction) -> Date? { isoFull.date(from: a.at) ?? isoFrac.date(from: a.at) }
    let googleHome = sat.first { $0.title == "Google" && $0.site.contains("google.com") }
    try check(googleHome != nil && !sat.contains { a in
                  a.title != "Google" && a.site.contains("google.com") && !a.site.contains("docs.")
                    && abs((when(a) ?? .distantPast).timeIntervalSince(when(googleHome!) ?? .distantFuture)) <= 120 },
              "agent tools fixture: the wordless Google page is kept with no results row within 2 minutes")
    if let id = f.typedKept.first(where: { try! f.store.hydrateTypedText($0, disclosure: .assistant, now: f.now)?.contains("launch checklist") == true }) {
        // Raw reads here: `words` also goes through AgentSharePolicy.shareable (nil on the WP-0 stub).
        func raw() -> Bool { ((try? f.store.hydrateTypedText(id, disclosure: .assistant, now: f.now)) ?? nil) != nil }
        try f.typed.setLocked(true)
        let lockedPolicy = f.typed.policy(), lockedRead = raw()
        // The store source answers as the bridge does: locked typing is an error the tools turn into a plain line.
        var lockedError: AgentBridgeError?
        do { _ = try f.typed.words([id]) } catch let e as AgentBridgeError { lockedError = e }
        try f.typed.setLocked(false)
        let openPolicy = f.typed.policy(), openRead = raw()
        try check(lockedPolicy.vault == .locked && !lockedRead && lockedError == .unavailable(.locked) && openPolicy.vault == .ready && openRead,
                  "agent tools fixture: locking the test vault hides typed words and unlocking brings them back (locked: \(lockedPolicy.vault), read \(lockedRead); unlocked: \(openPolicy.vault), read \(openRead))")
    } else { try check(false, "agent tools fixture: the Notes secrets row is readable") }
    let source = AgentNoTypedSource()
    try check(try source.words(["x"]).isEmpty && source.policy() == .unreachable, "agent tools: the no-words source shares nothing")
}

/// Registered in Checks/main.swift.
func runAgentToolsChecks(home: URL) throws {
    let fixture = try AgentToolsFixture.build(home: home)
    try runAgentToolsFixtureChecks(fixture)
    let state = AgentWPState.detect(fixture)
    print("agent tools evals: work packages real: " + AgentWP.allCases.map { "\($0.rawValue)=\(state.real[$0.rawValue] == true ? "yes" : "stub")" }.joined(separator: " ")
          + ", typing lane: " + (AgentToolsFixture.typingAppsOpen ? "owner" : "public"))
    let runner = AgentEvalRunner(fixture: fixture, state: state)
    var armedMisses: [String] = []
    for eval in AgentEvals.all {
        let r = runner.run(eval, keepReplies: false)
        let summary = "\(r.id) \(r.title): \(r.calls) calls, \(r.tokens.max() ?? 0) max tokens"
        switch r.status {
        case .pass: try check(true, "eval " + summary)
        case .fail: armedMisses.append(r.id); print("EVAL MISS (armed) " + summary + " — " + r.problems.joined(separator: "; "))
        case .expectedMiss: print("EVAL expected-miss (stubs) " + summary + " — " + r.problems.prefix(4).joined(separator: "; "))
        case .unexpectedPass: print("EVAL passes-on-stubs " + summary)
        case .notApplicable: print("EVAL n/a " + r.id + " " + r.title + ": " + (r.note ?? ""))
        }
    }
    try check(armedMisses.isEmpty, "agent tools evals: every eval whose work packages are real passes (misses: \(armedMisses.joined(separator: ", ")))")
    try check(AgentEvals.all.count == 35 && Set(AgentEvals.all.map(\.id)).count == 35 && AgentEvals.playbook.count == 11,
              "agent tools evals: 11 playbook questions and 24 regressions, unique ids")
    try runAgentQualityChecks(fixture)
    try runAgentHeadlineChecks(fixture)
}

/// Integrator (0.1.5 quality pass): replies an agent reads are about the period asked for, and grouped as people say.
func runAgentQualityChecks(_ f: AgentToolsFixture) throws {
    func run(_ name: String, _ args: [String: Any]) throws -> String { AgentTools.run(name: name, arguments: args, context: try f.context()).text }
    func line(_ text: String, _ needle: String) -> String { text.split(separator: "\n").first { $0.contains(needle) }.map(String.init) ?? "" }
    // Part of a day: visit counts, last times and active minutes are the period's (the memo was open at 10:00, 2:20, 5:40).
    let morning = try run("timeline", ["when": "yesterday morning"])
    let memo = line(morning, "Tallybird pricing memo")
    try check(memo.contains("10:00") && !memo.contains("visits") && !memo.contains("5:44") && !morning.contains("Jules Moreau") && !morning.contains("Day note:"),
              "agent timeline: \"yesterday morning\" shows the morning's visit and time only (\(memo))")
    try check(line(try run("timeline", ["when": "yesterday"]), "Tallybird pricing memo").contains("3 visits, last 5:44 PM"),
              "agent timeline: a whole day keeps every visit")
    let afternoon = try run("search", ["query": "pricing memo", "when": "yesterday afternoon"])
    let hit = line(afternoon, "Tallybird pricing memo")
    try check(hit.contains("2:20") && !hit.contains("visits") && afternoon.contains("yesterday afternoon"),
              "agent search: with when, an item's visits and time are the period's (\(hit))")
    // Email threads are their own group, never under People.
    var heading = ""
    var misplaced: [String] = []
    for l in try run("timeline", ["when": "today", "detail": "full"]).split(separator: "\n").map(String.init) {
        if !l.hasPrefix("-"), !l.hasPrefix(" "), !l.contains(" · ") { heading = l }
        if l.hasPrefix("- Email "), heading != "Email" { misplaced.append(l) }
    }
    try check(misplaced.isEmpty, "agent timeline: email threads are under Email, not People (\(misplaced))")
    // A web search is a moment: its time, not a span.
    try check(line(try run("timeline", ["when": "yesterday"]), "delaware franchise tax").contains("· 3:00 PM ·"), "agent timeline: a search shows the time it was made")
}

/// Integrator: `timeline` prints the day's headline once a day note exists (`MemoryStore: DayReviewHeadlineSource`,
/// AgentHeadline.swift), and never before. Runs after the evals: it writes the fixture's Saturday levels by code
/// (extractive, as the level writer does with no model), which the evals don't expect.
func runAgentHeadlineChecks(_ f: AgentToolsFixture) throws {
    let day = AgentToolsFixture.Day.yesterday.rawValue
    func headline() throws -> String? { try f.reader().dayReviewHeadline(day: day, timezone: f.timezone) }
    func timeline(typed: Bool) throws -> String {
        f.typed.typedWordsSetting = typed
        defer { f.typed.typedWordsSetting = true }
        return AgentTools.run(name: "timeline", arguments: ["when": day], context: try f.context()).text
    }
    try check(try headline() == nil && !(try timeline(typed: true)).contains("Day note:"), "day headline: none before the day has a day note")
    // Every moment of the day gets a plain note first (a day is written once none of its blocks waits on a moment).
    for moment in try f.store.dayLayers(day: day, timezone: f.timezone, limit: 500, now: f.now).activities where moment.generated == nil {
        guard let request = try? f.store.prepareNote(kind: "activity", day: day, timezone: f.timezone, activityID: moment.id, now: f.now) else { continue }
        _ = try? f.store.commitNote(NoteWriterOutput(requestID: request.id, title: moment.subject,
                                                     bullets: [NoteBullet(text: "Had \(moment.subject) open.", actionIDs: request.actions.map(\.id), assertion: "observed")],
                                                     generator: "local/synthetic", generatorVersion: "1"), now: f.now)
    }
    var rounds = 0
    while rounds < 30, try f.store.levelNotes(level: .day, periods: [day]).isEmpty {
        rounds += 1
        let work = try f.store.levelWork(timezone: f.timezone, now: f.now, backfillDays: 7, limit: 50).filter { $0.period == day }
        guard !work.isEmpty else { break }
        for request in work {
            let note = LevelGrounding.extractive(request)
            _ = try? f.store.commitLevel(request, title: note.title, lines: note.lines, generator: LevelWriterVersion.extractive, now: f.now)
        }
    }
    let stored = try f.store.levelNotes(level: .day, periods: [day]).first
    try check(stored != nil, "day headline: the fixture's Saturday gets a day note written by code (\(rounds) rounds)")
    guard let stored, let line = try headline() else {
        try check(stored.map(DayLevels.savedPlain) == true, "day headline: a day note exists, so a headline is read (unless saved plain)")
        return
    }
    let text = try timeline(typed: true)
    try check(text.contains("Day note: " + line) && !line.isEmpty, "day headline: timeline shows the day note's headline (\(line))")
    try check(AgentItems.noteLine(line, itemName: "") == line, "day headline: it passed the note-line filter (no send state, no draft, no filler)")
    if stored.typedDerived {
        try check(!(try timeline(typed: false)).contains("Day note:"), "day headline: a headline written from typed rows is left out while typed words are off")
    }
}

// MARK: - `MacMemChecks --agent-tools …` (for scripts/agent-tools-evals.py and the private run's self-test)

/// `--agent-tools evals-list` | `fixture <home>` | `run <home> [--json PATH] [--only ID,ID] [--replies] [--strict]`.
/// nil when the arguments are not for it. Synthetic data only: `<home>` must be new or empty.
func agentToolsCommand(_ arguments: [String]) -> Int32? {
    guard arguments.count >= 3, arguments[1] == "--agent-tools" else { return nil }
    let rest = Array(arguments.dropFirst(2))
    func value(_ name: String) -> String? { rest.firstIndex(of: name).flatMap { $0 + 1 < rest.count ? rest[$0 + 1] : nil } }
    func emit(_ value: some Encodable) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(value)); print()
    }
    func freshHome(_ path: String) throws -> URL {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
        guard entries.isEmpty else { throw MemError.invalid("--agent-tools needs a new or empty folder for the synthetic fixture: \(url.path)") }
        return url
    }
    do {
        switch rest[0] {
        case "evals-list":
            struct Table: Encodable { var always: [String: String]; var sendState: [String]; var ownWording: [String]; var personWords: [String]; var evals: [AgentEval]; var budgets: [String: Int] }
            try emit(Table(always: AgentEvals.always, sendState: AgentEvals.sendState, ownWording: AgentEvals.ownWording, personWords: AgentEvals.personWords, evals: AgentEvals.all,
                           budgets: ["timelineSummary": AgentBudget.timelineSummary, "timelineFull": AgentBudget.timelineFull,
                                     "search": AgentBudget.search, "details": AgentBudget.details, "status": AgentBudget.status]))
            return 0
        case "fixture":
            guard rest.count >= 2 else { return 64 }
            let f = try AgentToolsFixture.build(home: try freshHome(rest[1]))
            print(f.home.appendingPathComponent(AgentToolsFixture.manifestName).path)
            return 0
        case "run":
            guard rest.count >= 2 else { return 64 }
            let f = try AgentToolsFixture.build(home: try freshHome(rest[1]))
            try runAgentToolsFixtureChecks(f)
            let state = AgentWPState.detect(f)
            let only = value("--only").map { Set($0.split(separator: ",").map(String.init)) }
            let runner = AgentEvalRunner(fixture: f, state: state)
            let results = AgentEvals.all.filter { only?.contains($0.id) ?? true }.map { runner.run($0, keepReplies: rest.contains("--replies")) }
            struct Report: Encodable { var lane: String; var workPackages: [String: Bool]; var manifest: AgentToolsFixtureManifest; var results: [AgentEvalResult] }
            let report = Report(lane: AgentToolsFixture.typingAppsOpen ? "owner" : "public", workPackages: state.real, manifest: f.manifest, results: results)
            if let path = value("--json") {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                try encoder.encode(report).write(to: URL(fileURLWithPath: path), options: .atomic)
            } else { try emit(report) }
            let strict = rest.contains("--strict")
            return results.contains { $0.status == .fail || (strict && $0.status == .expectedMiss) } ? 1 : 0
        default:
            return 64
        }
    } catch {
        FileHandle.standardError.write(Data("agent-tools: \(error)\n".utf8))
        return 1
    }
}
