import Foundation
import MemoryCore
import PrivacyPolicy

/// agent-tools v2, WP-B (docs/agent-tools/plan.md §5): the read-time model AI apps see: title normalizing, the entity
/// parsers, items (grouping, visits, noise, typed rows, AI-chat sessions), note filtering, ranking and the collapsed
/// counts. Pure: actions are made in memory with `ActionProjection.make`; no store, no capture, no settings, no clock.
/// Synthetic data only: every title, name, host, address and note below is made up.
func runAgentModelChecks() throws {
    try agentTitleChecks()
    try agentParserChecks()
    try agentNoteChecks()
    try agentItemChecks()
}

// MARK: - Fixture helpers

private let agentDay = "2027-01-15"
private let agentZone = "UTC"
private let agentStart = ISO8601DateFormatter().date(from: "2027-01-15T09:00:00Z")!
private let agentNow = ISO8601DateFormatter().date(from: "2027-01-15T20:00:00Z")!
private let chrome = ("Google Chrome", "com.google.Chrome")

private func agentAction(_ id: String, _ seconds: Double, kind: String = "window.changed", app: String, bundle: String = "", title: String = "",
                         url: String = "", tool: String? = nil, link: String? = nil, unit: TypedUnitProvenance? = nil) -> CanonicalAction {
    var e = Evidence(id: id, at: isoPrecise(agentStart.addingTimeInterval(seconds)), kind: kind, app: app, bundle: bundle, title: title, url: url,
                     synthetic: true)
    e.titleTool = tool
    if let unit {
        e.captureProvenance = NativeCaptureProvenance(policyRevision: "r", classifierVersion: "sensitive-typing/v2+typed-scrub/v1", windowID: "w",
                                                      focusID: "f", checkedAt: e.at, generation: 1, unit: unit)
    }
    var a = ActionProjection.make(e)
    a.link = link
    return a
}

private func agentUnit(surface: String, field: String = "message", to: String? = nil) -> TypedUnitProvenance {
    TypedUnitProvenance(runID: "run", part: 1, sealReason: "idle", startedAt: "2027-01-15T09:00:00Z", keys: 10, edits: 0, withheld: 0,
                        surface: surface, field: field, send: "none", to: to)
}

private let sendStateWords = #"(?i)\b(drafts?|drafted|drafting|sent|unsent|delivered|undelivered|unread)\b"#

// MARK: - 1. Titles

private func agentTitleChecks() throws {
    let cases: [(raw: String, app: String, site: String, want: String)] = [
        ("(3) Home / X", "Google Chrome", "x.com", "Home"),
        ("Q3 plan - Google Docs - Google Chrome", "Google Chrome", "", "Q3 plan"),
        ("Q3 plan - Google Chrome - Work", "Google Chrome", "", "Q3 plan"),
        ("Inbox (12 unread) — Mail", "Mail", "", "Inbox"),
        ("Inbox (3) - Gmail", "Google Chrome", "mail.google.com", "Inbox"),
        ("\u{200e}Budget [4]  v2", "Fake Editor", "", "Budget v2"),
        ("✳ Fake session alpha", "Ghostty", "", "Fake session alpha"),
        ("Slack", "Slack", "", "Slack"),
        ("Fake report — Preview", "Preview", "", "Fake report"),
        ("Pre-launch - checklist", "Fake Editor", "", "Pre-launch - checklist"),
        ("A fake field guide | Example", "Google Chrome", "www.example.org", "A fake field guide"),
        ("Chat (2 new messages) - Fakechat", "Fakechat", "", "Chat"),
        ("", "Finder", "", ""),
    ]
    for c in cases {
        let got = AgentTitles.normalized(c.raw, app: c.app, site: c.site)
        try check(got == c.want, "agent titles: “\(c.raw)” is “\(c.want)” (got “\(got)”)")
    }
    let flicker = ["Budget", "budget (1)", "Budget — 80×24", "*Budget", "(2) Budget", "Budget [3]", "BUDGET - Fake Editor", "\u{200f}Budget"]
    let keys = Set(flicker.map { AgentTitles.flickerKey($0, app: "Fake Editor", site: "") })
    try check(keys.count == 1, "agent titles: flicker variants share one key (\(keys.sorted()))")
    try check(AgentTitles.flickerKey("Issue #12", app: "", site: "") != AgentTitles.flickerKey("Issue #13", app: "", site: "")
              && AgentTitles.flickerKey("Budget - 2026", app: "", site: "") != AgentTitles.flickerKey("Budget - 2027", app: "", site: ""),
              "agent titles: different numbers that name different things keep different keys")
}

// MARK: - 2. Parsers (one synthetic table per surface, with tricky titles)

private struct ParserCase { var surface: String; var action: CanonicalAction; var unit: TypedUnitProvenance? = nil; var want: AgentEntity }

private func agentParserChecks() throws {
    let (cApp, cBundle) = chrome
    func web(_ title: String, _ url: String, link: String? = nil) -> CanonicalAction {
        agentAction("p", 0, app: cApp, bundle: cBundle, title: title, url: url, link: link)
    }
    func app(_ name: String, _ bundle: String, _ title: String, kind: String = "window.changed", tool: String? = nil, unit: TypedUnitProvenance? = nil) -> CanonicalAction {
        agentAction("p", 0, kind: kind, app: name, bundle: bundle, title: title, tool: tool, unit: unit)
    }
    let ip = AgentEntities.hostAlias("10.0.0.7")
    let messagesUnit = agentUnit(surface: "text", to: "Dana Fakename")
    let table: [ParserCase] = [
        // Documents and forms.
        .init(surface: "document", action: web("Q3 plan - Google Docs", "https://docs.google.com/document/d/x/edit"), want: .document(kind: .doc, name: "Q3 plan")),
        .init(surface: "document", action: web("(2) Fake budget - Google Sheets", "https://docs.google.com/spreadsheets/d/x"), want: .document(kind: .sheet, name: "Fake budget")),
        .init(surface: "document", action: web("Pitch deck – Google Slides - Google Chrome", "https://docs.google.com/presentation/d/x"), want: .document(kind: .slides, name: "Pitch deck")),
        .init(surface: "document", action: web("Reading list - Google Docs", ""), want: .document(kind: .doc, name: "Reading list")),
        .init(surface: "document", action: web("My Drive - Google Drive", "https://drive.google.com/drive/my-drive"), want: .document(kind: .drive, name: "My Drive")),
        .init(surface: "document", action: app("Pages", "com.apple.iWork.Pages", "Essay outline.pages"), want: .document(kind: .pages, name: "Essay outline")),
        .init(surface: "document", action: app("Microsoft Excel", "com.microsoft.Excel", "Fake budget.xlsx"), want: .document(kind: .excel, name: "Fake budget")),
        // Integrator: a Chrome window with no recorded site whose title names the product is the same item as its page rows.
        .init(surface: "form", action: web("Fake grant intake - Tally", ""), want: .document(kind: .form, name: "Fake grant intake")),
        .init(surface: "form", action: web("Fake intake survey - Typeform", ""), want: .document(kind: .form, name: "Fake intake survey")),
        .init(surface: "form", action: web("Fake intake survey", "https://fakeco.typeform.com/to/x"), want: .document(kind: .form, name: "Fake intake survey")),
        .init(surface: "document", action: web("Fake roadmap - Notion", ""), want: .document(kind: .notion, name: "Fake roadmap")),
        .init(surface: "document", action: web("Fake roadmap", "https://www.notion.so/fakeco/x"), want: .document(kind: .notion, name: "Fake roadmap")),
        .init(surface: "document", action: web("Fake roadmap | Notion", "https://www.notion.so/fakeco/x"), want: .document(kind: .notion, name: "Fake roadmap")),
        .init(surface: "document", action: web("Fake vendor base - Airtable", ""), want: .document(kind: .airtable, name: "Fake vendor base")),
        .init(surface: "form", action: web("Fake grant application - Airtable", ""), want: .document(kind: .form, name: "Fake grant application")),
        .init(surface: "form", action: web("Studio residency application - Google Forms", "https://docs.google.com/forms/d/x/viewform"), want: .document(kind: .form, name: "Studio residency application")),
        .init(surface: "form", action: web("Untitled form", "https://docs.google.com/forms/d/x/edit", link: "https://docs.google.com/forms/d/x/edit"), want: .document(kind: .form, name: "Untitled form")),
        .init(surface: "form", action: web("Volunteer sign-up", "https://forms.gle/x"), want: .document(kind: .form, name: "Volunteer sign-up")),
        .init(surface: "form", action: web("Fake grant intake", "https://tally.so/r/x"), want: .document(kind: .form, name: "Fake grant intake")),
        .init(surface: "form", action: web("Scholarship application portal - Fake College", "https://apply.fakecollege.example"), want: .document(kind: .form, name: "Scholarship application portal - Fake College")),
        .init(surface: "page", action: web("Formatting tips for essays", "https://blog.example.org/x"), want: .page(title: "Formatting tips for essays", site: "blog.example.org")),
        // Web searches.
        .init(surface: "web_search", action: web("red boots - Google Search", "https://www.google.com/search?q=red+boots"), want: .webSearch(engine: "Google", query: "red boots")),
        .init(surface: "web_search", action: web("red boots", "https://www.google.com"), want: .webSearch(engine: "Google", query: "red boots")),
        .init(surface: "web_search", action: web("", "https://www.google.com/search?q=winter+tires"), want: .webSearch(engine: "Google", query: "winter tires")),
        .init(surface: "web_search", action: web("Google", "https://www.google.com"), want: .webSearch(engine: "Google", query: nil)),
        .init(surface: "web_search", action: web("tax deadline 2027 - Google Search - Google Chrome", ""), want: .webSearch(engine: "Google", query: "tax deadline 2027")),
        .init(surface: "web_search", action: web("fake query - Search", "https://www.bing.com/search?q=fake+query"), want: .webSearch(engine: "Bing", query: "fake query")),
        .init(surface: "web_search", action: web("123456 - Google Search", "https://www.google.com"), want: .webSearch(engine: "Google", query: nil)),
        .init(surface: "web_search", action: web("", "https://www.google.com", link: "https://www.google.com/search?q=moss+care"), want: .webSearch(engine: "Google", query: "moss care")),
        // AI chats (content comes from typed prompts, not titles).
        .init(surface: "ai_chat", action: web("", "https://claude.ai/chat/x"), want: .aiChat(app: "Claude", title: nil)),
        .init(surface: "ai_chat", action: web("ChatGPT", "https://chatgpt.com/c/x"), want: .aiChat(app: "ChatGPT", title: nil)),
        .init(surface: "ai_chat", action: web("Gemini", "https://gemini.google.com/app"), want: .aiChat(app: "Gemini", title: nil)),
        .init(surface: "ai_chat", action: app("Claude", "com.anthropic.claudefordesktop", "Claude"), want: .aiChat(app: "Claude", title: nil)),
        .init(surface: "ai_chat", action: app("ChatGPT", "com.openai.chat", "Fake trip planning"), want: .aiChat(app: "ChatGPT", title: "Fake trip planning")),
        .init(surface: "ai_chat", action: web("Claude", ""), want: .aiChat(app: "Claude", title: nil)),
        // People.
        .init(surface: "person", action: app("Messages", "com.apple.MobileSMS", "Maybe: Sam Fakename"), want: .person(name: "Sam Fakename")),
        .init(surface: "person", action: app("Messages", "com.apple.MobileSMS", "Maya, Sam & 2 more"), want: .person(name: "Maya, Sam & 2 more")),
        .init(surface: "person", action: app("Messages", "com.apple.MobileSMS", "+1 (555) 010-0199"), want: .person(name: "+1 (555) 010-0199")),
        .init(surface: "person", action: app("Messages", "com.apple.MobileSMS", "Dana Fakename", kind: "keyboard.text_input", unit: messagesUnit), unit: messagesUnit, want: .person(name: "Dana Fakename")),
        .init(surface: "person", action: app("Slack", "com.tinyspeck.slackmacgap", "Priya Fake (DM) - Fakeco - Slack"), want: .person(name: "Priya Fake")),
        .init(surface: "person", action: app("Messages", "com.apple.MobileSMS", "Messages"), want: .app(name: "Messages", title: "", lowValue: false)),
        .init(surface: "person", action: app("Messages", "com.apple.MobileSMS", "New Message"), want: .app(name: "Messages", title: "", lowValue: false)),
        .init(surface: "person", action: app("Messages", "com.apple.MobileSMS", "", kind: "keyboard.text_input"), want: .app(name: "Messages", title: "", lowValue: false)),
        // Email.
        .init(surface: "email", action: app("Mail", "com.apple.mail", "Re: Fake lease renewal"), want: .email(subject: "Re: Fake lease renewal")),
        .init(surface: "email", action: app("Mail", "com.apple.mail", "Inbox — 1,234 messages, 5 unread"), want: .email(subject: nil)),
        .init(surface: "email", action: app("Mail", "com.apple.mail", "Sent Messages"), want: .email(subject: nil)),
        .init(surface: "email", action: web("Fwd: Fake invoice 42 - someone@example.test - Gmail", "https://mail.google.com/mail/u/0"), want: .email(subject: "Fwd: Fake invoice 42")),
        .init(surface: "email", action: web("Drafts (3) - someone@example.test - Gmail", "https://mail.google.com/mail/u/0"), want: .email(subject: nil)),
        .init(surface: "email", action: web("Sent Mail - someone@example.test - Gmail", "https://mail.google.com/mail/u/0"), want: .email(subject: nil)),
        // Terminal: hosts and addresses become an alias.
        .init(surface: "terminal", action: app("Terminal", "com.apple.Terminal", "dev@10.0.0.7: ~/projects/fakeapp"), want: .terminal(tool: nil, project: "fakeapp", host: ip)),
        .init(surface: "terminal", action: app("Ghostty", "com.mitchellh.ghostty", "ssh dev@10.0.0.7"), want: .terminal(tool: nil, project: nil, host: ip)),
        .init(surface: "terminal", action: app("iTerm2", "com.googlecode.iterm2", "fakeapp — claude"), want: .terminal(tool: "Claude Code", project: "fakeapp", host: nil)),
        .init(surface: "terminal", action: app("Ghostty", "com.mitchellh.ghostty", "Fake session alpha", tool: "Claude Code"), want: .terminal(tool: "Claude Code", project: "Fake session alpha", host: nil)),
        .init(surface: "terminal", action: app("Terminal", "com.apple.Terminal", "~ — -zsh — 80×24"), want: .terminal(tool: nil, project: nil, host: nil)),
        .init(surface: "terminal", action: app("Terminal", "com.apple.Terminal", "ops@buildbox-7: ~/srv/fakeapi/"), want: .terminal(tool: nil, project: "fakeapi", host: AgentEntities.hostAlias("buildbox-7"))),
        .init(surface: "terminal", action: app("Terminal", "com.apple.Terminal", "admin@[fd00::7:8:9]: ~"), want: .terminal(tool: nil, project: nil, host: AgentEntities.hostAlias("fd00::7:8:9"))),
        .init(surface: "terminal", action: app("Terminal", "com.apple.Terminal", "someone@Fakes-MacBook-Pro ~ %"), want: .terminal(tool: nil, project: nil, host: nil)),
        .init(surface: "terminal", action: app("Terminal", "com.apple.Terminal", "ping 192.168.1.20"), want: .terminal(tool: nil, project: "ping", host: AgentEntities.hostAlias("192.168.1.20"))),
        .init(surface: "terminal", action: app("Ghostty", "com.mitchellh.ghostty", "npm run dev — fakeapp"), want: .terminal(tool: nil, project: "npm run dev", host: nil)),
        .init(surface: "terminal", action: app("Terminal", "com.apple.Terminal", "fakeapp — ssh -p 2222 fakebox"), want: .terminal(tool: nil, project: "fakeapp", host: AgentEntities.hostAlias("fakebox"))),
        // Feeds and posts.
        .init(surface: "feed", action: web("(3) Home / X", "https://x.com/home"), want: .feed(site: "X")),
        .init(surface: "feed", action: web("Fake Person on X: \"a fake post\" / X", "https://x.com/fake/status/1"), want: .feed(site: "X")),
        .init(surface: "feed", action: web("Home / X", ""), want: .feed(site: "X")),
        .init(surface: "feed", action: web("YouTube", "https://www.youtube.com/"), want: .feed(site: "YouTube")),
        .init(surface: "feed", action: web("Reddit - Dive into anything", "https://www.reddit.com/"), want: .feed(site: "Reddit")),
        .init(surface: "feed", action: web("Hacker News", "https://news.ycombinator.com/"), want: .feed(site: "Hacker News")),
        .init(surface: "feed", action: web("(4) Feed | LinkedIn", "https://www.linkedin.com/feed/"), want: .feed(site: "LinkedIn")),
        .init(surface: "page", action: web("(5) How to fake bake bread - YouTube", "https://www.youtube.com/watch"), want: .page(title: "How to fake bake bread", site: "youtube.com")),
        // Finder.
        .init(surface: "folder", action: app("Finder", "com.apple.finder", "Fake Project Assets"), want: .app(name: "Finder", title: "Fake Project Assets", lowValue: false)),
        .init(surface: "folder", action: app("Finder", "com.apple.finder", "Downloads"), want: .app(name: "Finder", title: "Downloads", lowValue: true)),
        // Other pages, apps, system UI and DayDream.
        .init(surface: "page", action: web("A fake field guide to moss - Example Blog", "https://www.example.org/moss"), want: .page(title: "A fake field guide to moss - Example Blog", site: "example.org")),
        .init(surface: "page", action: web("New Tab", "https://www.example.org"), want: .app(name: "Google Chrome", title: "New Tab", lowValue: true)),
        .init(surface: "app", action: app("Xcode", "com.apple.dt.Xcode", "FakeApp — ContentView.swift"), want: .app(name: "Xcode", title: "FakeApp — ContentView.swift", lowValue: false)),
        .init(surface: "app", action: app("System Settings", "com.apple.systempreferences", "Wi-Fi"), want: .app(name: "System Settings", title: "Wi-Fi", lowValue: true)),
        .init(surface: "app", action: app("DayDream", "com.getnorthlight.daydream", "DayDream"), want: .app(name: "DayDream", title: "DayDream", lowValue: true)),
    ]
    var coverage: [String: (pass: Int, total: Int)] = [:]
    for c in table {
        let got = AgentEntities.entity(c.action, unit: c.unit)
        let ok = got == c.want
        coverage[c.surface, default: (0, 0)].total += 1
        if ok { coverage[c.surface]!.pass += 1 }
        try check(ok, "agent parser (\(c.surface)): “\(c.action.title)” on “\(c.action.site)” in \(c.action.app) is \(c.want) (got \(got))")
    }
    for surface in coverage.keys.sorted() { print("COVERAGE: agent parser \(surface) \(coverage[surface]!.pass)/\(coverage[surface]!.total)") }
    // Aliases: stable, never the host, and the same host is the same alias.
    try check(ip == AgentEntities.hostAlias("10.0.0.7") && ip.hasPrefix("host-") && ip.count == 9 && !ip.contains("10"),
              "agent parser: a host alias is stable and holds no part of the address (\(ip))")
    for c in table where c.surface == "terminal" {
        let text = "\(AgentEntities.entity(c.action, unit: c.unit))"
        try check(!text.contains("10.0.0.7") && !text.contains("dev@") && !text.contains("192.168") && !text.contains("buildbox") && !text.contains("fd00")
                  && !text.contains("ops@") && !text.contains("fakebox"),
                  "agent parser: terminal “\(c.action.title)” names no host or address")
    }
    // Keys: case and flicker fold into one key, kinds never collide.
    try check(AgentEntity.document(kind: .doc, name: "Q3 Plan").key == AgentEntity.document(kind: .doc, name: "q3 plan").key
              && AgentEntity.document(kind: .doc, name: "Q3 plan").key != AgentEntity.document(kind: .sheet, name: "Q3 plan").key
              && AgentEntity.page(title: "Moss", site: "a.example").key != AgentEntity.page(title: "Moss", site: "b.example").key,
              "agent parser: entity keys fold case and keep kinds and sites apart")
}

// MARK: - 3. Notes

private func agentNoteChecks() throws {
    let cases: [(line: String, item: String, want: String?)] = [
        ("In Terminal.", "fakeapp", nil),
        ("In ChatGPT.", "ChatGPT", nil),
        ("Viewed Claude.", "Claude", nil),
        ("Viewed ChatGPT conversation about trips", "ChatGPT", nil),
        ("Viewed Q3 plan.", "Q3 plan", nil),
        ("Viewed the Q3 plan page", "Q3 plan", nil),
        ("Q3 plan", "Q3 plan", nil),
        ("Observed Fake page in Google Chrome; reading is not established.", "Fake page", nil),
        ("Typed a draft in Messages (a few words)", "Messages", nil),
        ("Clicked the Submit button", "Fake form", nil),
        ("Pressed Return in Terminal", "fakeapp", nil),
        ("Message delivered", "Sam Fakename", nil),
        ("Unread messages from Sam", "Sam Fakename", nil),
        ("Had Google Chrome open", "Fake page", nil),
        ("(draft) Texted Sam about the fake picnic", "Sam Fakename", "Texted Sam about the fake picnic"),
        ("Replied to Dana about the fake lease (not sent).", "Fake lease renewal", "Replied to Dana about the fake lease."),
        ("Wrote to Dana about the fake lease, still a draft", "Dana Fakename", "Wrote to Dana about the fake lease"),
        ("Drafted a reply to Dana about the fake lease", "Fake lease renewal", "Wrote a reply to Dana about the fake lease"),
        ("Sent a text to Sam about dinner", "Sam Fakename", "Texted Sam about dinner"),
        ("Sent the fake deck to Dana", "Dana Fakename", "Shared the fake deck with Dana"),
        ("Read How fake moss grows", "How fake moss grows", "Read How fake moss grows"),
        ("(interpretation) Compared two fake apartment listings", "Fake listings", "(interpretation) Compared two fake apartment listings"),
        ("(reported) Claude said the fake build passed", "Claude", "(reported) Claude said the fake build passed"),
        ("Edited the cover letter draft", "Cover letter draft", "Edited the cover letter draft"),
        ("In the Q3 plan, rewrote the pricing section", "Q3 plan", "In the Q3 plan, rewrote the pricing section"),
        ("Asked Claude about fake tax deadlines for freelancers", "Claude", "Asked Claude about fake tax deadlines for freelancers"),
        ("Viewed pricing for the fake Pro plan", "Fakeco", "Viewed pricing for the fake Pro plan"),
    ]
    for c in cases {
        let got = AgentItems.noteLine(c.line, itemName: c.item)
        try check(got == c.want, "agent notes: “\(c.line)” on “\(c.item)” is \(c.want.map { "“\($0)”" } ?? "dropped") (got \(got.map { "“\($0)”" } ?? "dropped"))")
        if let got {
            try check(got.replacingOccurrences(of: c.item, with: "", options: .caseInsensitive).range(of: sendStateWords, options: .regularExpression) == nil
                      && got.range(of: #"^In \w+\.$"#, options: .regularExpression) == nil && !got.contains("(draft)"),
                      "agent notes: a kept line states no send state and is no tautology (“\(got)”)")
        }
    }
}

// MARK: - 4. Items, ranking, collapse

private func agentItemChecks() throws {
    let policyOn = AgentSharePolicy(typedWords: true)
    let policyOff = AgentSharePolicy(typedWords: false, typedWordsOff: .settingOff)
    let (cApp, cBundle) = chrome
    var actions: [CanonicalAction] = []
    var typed: [String: AgentTypedFact] = [:]
    var noiseIDs: [String] = []
    var n = 0
    func row(_ t: Double, kind: String = "window.changed", app: String, bundle: String = "", title: String = "", url: String = "", tool: String? = nil,
             unit: TypedUnitProvenance? = nil, words: Int = 0) -> String {
        n += 1
        let id = String(format: "a%04d", n)
        actions.append(agentAction(id, t, kind: kind, app: app, bundle: bundle, title: title, url: url, tool: tool, unit: unit))
        if kind == "keyboard.text_input" { typed[id] = AgentTypedFact(actionID: id, unit: unit, words: words) }
        if !["window.changed", "keyboard.text_input"].contains(kind) { noiseIDs.append(id) }
        return id
    }
    func noise(_ t: Double, app: String) {
        for (i, kind) in ["mouse.click", "app.activated", "keyboard.shortcut", "keyboard.submit", "mouse.context_menu", "mouse.scroll"].enumerated() {
            _ = row(t + Double(i), kind: kind, app: app, title: "Clicked something")
        }
    }
    // 09:00 a 60-minute X feed: a row every 30 s, with scrolls and clicks.
    var t = 0.0
    while t < 3600 {
        _ = row(t, app: cApp, bundle: cBundle, title: t.truncatingRemainder(dividingBy: 90) == 0 ? "(3) Home / X" : "Home / X", url: "https://x.com/home")
        if t.truncatingRemainder(dividingBy: 300) == 0 { noise(t + 5, app: cApp) }
        t += 30
    }
    // 10:00 a 90-second application form, typed into.
    let formTitle = "Studio residency application - Google Forms"
    for s in stride(from: 3600.0, through: 3690, by: 30) { _ = row(s, app: cApp, bundle: cBundle, title: formTitle, url: "https://docs.google.com/forms/d/x") }
    let formTyped = row(3640, kind: "keyboard.text_input", app: cApp, bundle: cBundle, title: formTitle, url: "https://docs.google.com/forms/d/x",
                        unit: agentUnit(surface: "form", field: "textArea"), words: 40)
    // 10:02 Claude desktop, a morning session with prompts; 14:00 an afternoon session.
    _ = row(3720, app: "Claude", bundle: "com.anthropic.claudefordesktop", title: "Claude")
    let claudeAM = row(3750, kind: "keyboard.text_input", app: "Claude", bundle: "com.anthropic.claudefordesktop", title: "Claude",
                       unit: agentUnit(surface: "ai"), words: 25)
    _ = row(4200, app: "Claude", bundle: "com.anthropic.claudefordesktop", title: "Claude")
    // 10:15 Messages: the window shows Sam, a typed row to Dana (its own recipient), then a typed row with no recipient.
    _ = row(4500, app: "Messages", bundle: "com.apple.MobileSMS", title: "Sam Fakename")
    let toDana = row(4530, kind: "keyboard.text_input", app: "Messages", bundle: "com.apple.MobileSMS",
                     unit: agentUnit(surface: "text", to: "Dana Fakename"), words: 12)
    let noRecipient = row(4560, kind: "keyboard.text_input", app: "Messages", bundle: "com.apple.MobileSMS", unit: agentUnit(surface: "other"), words: 3)
    // 10:20 a Google search typed into the home page, then its results.
    _ = row(4800, app: cApp, bundle: cBundle, title: "Google", url: "https://www.google.com")
    let searchTyped = row(4810, kind: "keyboard.text_input", app: cApp, bundle: cBundle, title: "Google", url: "https://www.google.com",
                          unit: agentUnit(surface: "search", field: "search"), words: 3)
    _ = row(4815, app: cApp, bundle: cBundle, title: "fake moss care - Google Search", url: "https://www.google.com/search?q=fake+moss+care")
    // 10:30 a Google Doc, three visits (the 2nd within 10 minutes of the 1st, the 3rd later), with clicks inside.
    let doc = "Fake offer letter - Google Docs"
    _ = row(5400, app: cApp, bundle: cBundle, title: doc, url: "https://docs.google.com/document/d/y")
    _ = row(5640, kind: "mouse.click", app: cApp, title: doc)
    _ = row(5880, kind: "mouse.click", app: cApp, title: doc)
    _ = row(6120, app: "Mail", bundle: "com.apple.mail", title: "Re: Fake lease renewal")
    _ = row(6300, app: cApp, bundle: cBundle, title: doc, url: "https://docs.google.com/document/d/y")
    _ = row(6360, app: "Mail", bundle: "com.apple.mail", title: "Sent Messages")
    _ = row(9000, app: cApp, bundle: cBundle, title: doc, url: "https://docs.google.com/document/d/y")
    _ = row(9060, app: "Mail", bundle: "com.apple.mail", title: "Inbox — 4 messages")
    // 11:00 a terminal: Claude Code on a project, a bare shell, an ssh session.
    _ = row(10800, app: "Ghostty", bundle: "com.mitchellh.ghostty", title: "Fake session alpha", tool: "Claude Code")
    _ = row(10900, app: "Ghostty", bundle: "com.mitchellh.ghostty", title: "~")
    _ = row(11000, app: "Ghostty", bundle: "com.mitchellh.ghostty", title: "ssh dev@10.0.0.7")
    // 11:10 300 repeated, flickering editor rows.
    for i in 0..<300 {
        let titles = ["Fake notes", "Fake notes (1)", "(2) Fake notes", "Fake notes — 80×24", "\u{200e}Fake notes"]
        _ = row(11400 + Double(i), app: "Fake Editor", bundle: "com.example.fakeeditor", title: titles[i % titles.count])
    }
    // 12:00 System Settings, DayDream's own window, Finder.
    _ = row(14400, app: "System Settings", bundle: "com.apple.systempreferences", title: "Wi-Fi")
    _ = row(14460, app: "DayDream", bundle: "com.getnorthlight.daydream", title: "DayDream")
    _ = row(14520, app: "Finder", bundle: "com.apple.finder", title: "Fake Project Assets")
    // 14:00 Claude desktop again.
    _ = row(18000, app: "Claude", bundle: "com.anthropic.claudefordesktop", title: "Claude")
    let claudePM = row(18030, kind: "keyboard.text_input", app: "Claude", bundle: "com.anthropic.claudefordesktop", title: "Claude",
                       unit: agentUnit(surface: "ai"), words: 30)
    _ = row(18600, app: "Fake Editor", bundle: "com.example.fakeeditor", title: "Fake notes")
    // 15:00 the ChatGPT app flickers between its chat's title and its own name; Xcode shows an untitled window.
    for (i, title) in ["Fake trip planning", "ChatGPT", "Fake trip planning", "ChatGPT"].enumerated() {
        _ = row(21600 + Double(i) * 20, app: "ChatGPT", bundle: "com.openai.chat", title: title)
    }
    _ = row(21700, app: "Xcode", bundle: "com.apple.dt.Xcode", title: "FakeApp — ContentView.swift")
    _ = row(21760, app: "Xcode", bundle: "com.apple.dt.Xcode", title: "")
    _ = row(21820, app: "Xcode", bundle: "com.apple.dt.Xcode", title: "FakeApp — ContentView.swift")
    // A row from the day before never joins this day.
    actions.append(agentAction("yesterday", -36000, app: cApp, bundle: cBundle, title: "Old fake doc - Google Docs", url: "https://docs.google.com/document/d/z"))
    let notes = [
        AgentNoteInput(actionIDs: [formTyped], lines: ["In Google Chrome.", "(draft) Filled in the residency application form", "Viewed Studio residency application."]),
        AgentNoteInput(actionIDs: [claudeAM], lines: ["Viewed Claude.", "Asked Claude about fake residency deadlines"]),
        AgentNoteInput(actionIDs: [toDana, noRecipient], lines: ["Texted Dana about the fake picnic (not sent).", "Message delivered", "In Messages."]),
    ]
    let input = AgentDayInput(day: agentDay, timezone: agentZone, actions: actions.shuffledDeterministically(), typed: typed, notes: notes)
    let items = AgentItems.items(input, policy: policyOn, now: agentNow)
    func find(_ e: AgentEntity) -> [AgentItem] { items.filter { $0.entity == e } }
    let form = find(.document(kind: .form, name: "Studio residency application"))
    let feed = find(.feed(site: "X"))
    try check(form.count == 1 && feed.count == 1, "agent items: one form item and one feed item (\(form.count), \(feed.count))")
    if let f = form.first, let x = feed.first {
        try check(f.score > x.score && items.firstIndex(of: f)! < items.firstIndex(of: x)!,
                  "agent rank (required): a 90-second application form (\(f.minutes) min, \(f.score)) ranks above a 60-minute feed (\(x.minutes) min, \(x.score))")
        try check(x.minutes >= 59 && f.minutes <= 2, "agent items: minutes counted per row, capped (feed \(x.minutes), form \(f.minutes))")
        try check(f.typedIDs == [formTyped] && f.typedWords == 40, "agent items: a typed row joins the form it was typed in")
    }
    // The same regression with typing off and with a long feed day.
    let off = AgentItems.items(input, policy: policyOff, now: agentNow)
    if let f = off.first(where: { $0.entity.kind == .form }), let x = off.first(where: { $0.entity == .feed(site: "X") }) {
        try check(f.score > x.score, "agent rank: the form still outranks the feed with typed words off")
    } else { try check(false, "agent items: typing off keeps the form and feed items") }
    try check(off.first(where: { $0.entity == .person(name: "Sam Fakename") })?.typedWords == 0,
              "agent items: with typed words off, a Messages typed row's count never goes to the window's person")
    try check(off.allSatisfy { $0.typedIDs.isEmpty } && !off.contains(where: { $0.actionIDs.contains(toDana) }),
              "agent items: with typed words off, no typed row is listed in any item")
    // Noise: clicks, activations, shortcuts, Return, context menus and scrolls never become items or members.
    let members = Set(items.flatMap(\.actionIDs))
    try check(noiseIDs.allSatisfy { !members.contains($0) }, "agent items: no click, activation, key press, scroll or context-menu row is an item member")
    try check(!items.contains { AgentEntities.name($0.entity).hasPrefix("Clicked") }, "agent items: noise rows never name an item")
    // Flicker: 300 repeated rows with counts, glyph marks and sizes are one item with one visit.
    let notesItems = items.filter { if case .app("Fake Editor", _, _) = $0.entity { return true }; return false }
    try check(notesItems.count == 1 && notesItems[0].visits.count == 2, "agent items: 300 flickering rows are one item (\(notesItems.count) items, \(notesItems.first?.visits.count ?? 0) visits)")
    // Visits: a gap over 10 minutes starts a new one; clicks inside a visit count its time.
    if let d = find(.document(kind: .doc, name: "Fake offer letter")).first {
        try check(d.visits.count == 2, "agent items: the doc's visits split only on gaps over 10 minutes (\(d.visits.count))")
        try check(d.minutes >= 12, "agent items: clicks inside the doc add its time (\(d.minutes) min)")
    } else { try check(false, "agent items: the Google Doc is an item") }
    // Claude: two sessions, two items, each with its own prompt; ids differ.
    let claude = find(.aiChat(app: "Claude", title: nil))
    try check(claude.count == 2 && Set(claude.map(\.id)).count == 2 && Set(claude.flatMap(\.typedIDs)) == [claudeAM, claudePM],
              "agent items: an untitled Claude block splits into its two sessions (\(claude.count))")
    try check(claude.allSatisfy { AgentItems.itemKey($0, timezone: agentZone).contains("|@") }, "agent items: a session item's key carries its start")
    try check(items.allSatisfy { [AgentItemID.make(day: agentDay, key: AgentItems.itemKey($0, timezone: agentZone)),
                                  AgentItemID.make(day: agentDay, key: AgentItems.itemKey($0, timezone: agentZone), length: 6)].contains($0.id) },
              "agent items: every id is the hash of its item key")
    // Messages: the typed row goes to its own recipient, never the window's person; a row with no recipient borrows nobody.
    try check(find(.person(name: "Dana Fakename")).first?.typedIDs == [toDana], "agent items: a text goes to its own recipient")
    try check(find(.person(name: "Sam Fakename")).first?.typedIDs.isEmpty == true
              && find(.app(name: "Messages", title: "", lowValue: false)).first?.typedIDs == [noRecipient],
              "agent items: a Messages typed row never borrows the window's person")
    // A search typed into the home page joins the results that follow it, and so does the home page row.
    try check(find(.webSearch(engine: "Google", query: "fake moss care")).first?.typedIDs == [searchTyped], "agent items: a typed search joins its results")
    try check(find(.webSearch(engine: "Google", query: nil)).isEmpty && find(.webSearch(engine: "Google", query: "fake moss care")).first?.actionIDs.count == 3,
              "agent items: the engine's home page right before the results joins them")
    // Untitled rows join the titled window they flicker with.
    try check(find(.aiChat(app: "ChatGPT", title: "Fake trip planning")).first?.actionIDs.count == 4 && find(.aiChat(app: "ChatGPT", title: nil)).isEmpty,
              "agent items: the ChatGPT app's own-name title joins the chat it flickers with")
    try check(find(.app(name: "Xcode", title: "FakeApp — ContentView.swift", lowValue: false)).first?.actionIDs.count == 3
              && find(.app(name: "Xcode", title: "", lowValue: false)).isEmpty, "agent items: an untitled window joins the titled one in its app")
    // Terminal: the bare shell joins Claude Code's item; the ssh host is an alias.
    let cc = find(.terminal(tool: "Claude Code", project: "Fake session alpha", host: nil))
    try check(cc.count == 1 && cc[0].actionIDs.count == 2 && find(.terminal(tool: nil, project: nil, host: nil)).isEmpty,
              "agent items: a bare shell joins the terminal item before it")
    try check(find(.terminal(tool: nil, project: nil, host: AgentEntities.hostAlias("10.0.0.7"))).count == 1, "agent items: the ssh session is its own aliased item")
    // The day before is not in this day.
    try check(!members.contains("yesterday"), "agent items: rows outside the local day are left out")
    // Notes: labels only, filtered, attached to the item they name.
    if let f = form.first {
        try check(f.noteLines == ["Filled in the residency application form"], "agent items: the form's note lines are filtered (\(f.noteLines))")
    }
    try check(claude.flatMap(\.noteLines) == ["Asked Claude about fake residency deadlines"], "agent items: “Viewed Claude.” is dropped, the question is kept")
    try check(find(.person(name: "Dana Fakename")).first?.noteLines == ["Texted Dana about the fake picnic."], "agent items: a text's note has no send state")
    // No item text contains a send state or a tautology (required).
    for item in items {
        let texts = [AgentEntities.name(item.entity)] + item.noteLines
        try check(texts.allSatisfy { $0.range(of: sendStateWords, options: .regularExpression) == nil && !$0.contains("not established") },
                  "agent items (required): no send state in “\(texts.joined(separator: " / "))”")
        try check(item.noteLines.allSatisfy { $0.range(of: #"^In \w+\.$"#, options: .regularExpression) == nil && !$0.hasPrefix("Viewed Claude") },
                  "agent items (required): no tautological note on “\(AgentEntities.name(item.entity))”")
    }
    // Mail views ("Sent Messages", "Inbox") are the mailbox item, never a subject.
    try check(find(.email(subject: nil)).count == 1 && find(.email(subject: "Re: Fake lease renewal")).count == 1, "agent items: mailbox views fold into one item")
    try check(AgentEntity.email(subject: "Re: Fake lease renewal").key == AgentEntity.email(subject: "Fake lease renewal").key
              && AgentEntity.email(subject: "Fwd: RE: Fake lease renewal").key == AgentEntity.email(subject: "fake lease renewal").key,
              "agent items: an email thread is one item, its subject shown as written (reply prefixes fold in the key)")
    // Ranking by kind: DayDream last, system UI below pages, keyword doc above the plain one.
    let dd = items.first { if case .app("DayDream", _, true) = $0.entity { return true }; return false }
    try check(dd?.id == items.last?.id, "agent rank: DayDream's own window ranks last")
    let plain = AgentItem(id: "", day: agentDay, entity: .document(kind: .doc, name: "Fake notes on moss"), firstAt: agentStart, lastAt: agentStart,
                          visits: [AgentVisit(start: agentStart, end: agentStart)], minutes: 1, actionIDs: [], typedIDs: [], typedWords: 0, noteLines: [], score: 0)
    var offer = plain; offer.entity = .document(kind: .doc, name: "Fake offer letter")
    var due = plain; due.entity = .page(title: "Fake assignment due Friday", site: "example.edu")
    var page = plain; page.entity = .page(title: "Fake moss facts", site: "example.org")
    var heavyFeed = plain; heavyFeed.entity = .feed(site: "YouTube"); heavyFeed.minutes = 600; heavyFeed.visits = Array(repeating: heavyFeed.visits[0], count: 40)
    var heavySystem = heavyFeed; heavySystem.entity = .app(name: "System Settings", title: "Wi-Fi", lowValue: true)
    try check(AgentRank.score(offer, now: agentNow) > AgentRank.score(plain, now: agentNow)
              && AgentRank.score(due, now: agentNow) > AgentRank.score(page, now: agentNow),
              "agent rank: keywords (offer, assignment, due) raise an item")
    var mailbox = heavyFeed; mailbox.entity = .email(subject: nil)
    var bareSearch = plain; bareSearch.entity = .webSearch(engine: "Google", query: nil)
    var search = plain; search.entity = .webSearch(engine: "Google", query: "fake moss care")
    try check(AgentRank.score(mailbox, now: agentNow) < AgentRank.score(page, now: agentNow)
              && AgentRank.score(bareSearch, now: agentNow) < AgentRank.score(search, now: agentNow),
              "agent rank: a mailbox view sits with feeds, a search with no words with pages")
    try check(AgentRank.score(heavyFeed, now: agentNow) < AgentRank.score(page, now: agentNow)
              && AgentRank.score(heavySystem, now: agentNow) < AgentRank.score(page, now: agentNow),
              "agent rank: 10 hours of feed or system UI never outranks a one-minute page")
    try check(!AgentRank.keywordHit("Produce format examples") && AgentRank.keywordHit("Exam 2 review") && AgentRank.keywordHit("Fake offers"),
              "agent rank: keywords match whole words only")
    var custom = AgentRank.Weights.standard; custom.base[.feed] = 500; custom.lowTierBonusCap = 0
    try check(AgentRank.score(heavyFeed, now: agentNow, weights: custom) > AgentRank.score(offer, now: agentNow, weights: custom)
              && AgentRank.score(plain, now: agentNow, weights: .standard, daysSeen: 3) > AgentRank.score(plain, now: agentNow),
              "agent rank: weights are configurable and days seen count")
    var older = plain; older.lastAt = agentNow.addingTimeInterval(-3 * 86400)
    try check(AgentRank.score(plain, now: agentNow) > AgentRank.score(older, now: agentNow), "agent rank: recency breaks ties")
    // Ids: valid, unique, the same on a second call.
    try check(items.allSatisfy { AgentItemID.isValid($0.id) && $0.id.hasPrefix("0115-") } && Set(items.map(\.id)).count == items.count,
              "agent items: every id is valid and unique (\(items.count) items)")
    let again = AgentItems.items(AgentDayInput(day: agentDay, timezone: agentZone, actions: actions, typed: typed, notes: notes), policy: policyOn, now: agentNow)
    try check(again.map(\.id) == items.map(\.id) && again == items, "agent items: the same day gives the same items and ids, whatever the input order")
    // Collapsed counts add up, and no form, document or person is dropped silently (required).
    for limit in [0, 3, 5, 12, 100] {
        let (shown, collapsed) = AgentItems.summary(items, limit: limit)
        let pinnedShown = shown.filter { [.form, .document, .person].contains($0.entity.kind) }.count
        let pinnedAll = items.filter { [.form, .document, .person].contains($0.entity.kind) }.count
        let pinnedCounted = (collapsed.byKind[.form] ?? 0) + (collapsed.byKind[.document] ?? 0) + (collapsed.byKind[.person] ?? 0)
        try check(shown.count + collapsed.total == items.count && collapsed.byKind.values.reduce(0, +) == collapsed.total
                  && shown.count == min(limit, items.count) && pinnedShown + pinnedCounted == pinnedAll
                  && pinnedShown == min(pinnedAll, limit),
                  "agent items (required): collapsed counts add up at limit \(limit) (\(shown.count) shown + \(collapsed.total) collapsed = \(items.count))")
    }
    // Cost: a heavy day (20,000 rows, mostly repeats, with noise) is one pass.
    var heavy: [CanonicalAction] = []
    let heavyApps: [(String, String, String)] = [(cApp, cBundle, "https://docs.google.com/document/d/q"), ("Ghostty", "com.mitchellh.ghostty", ""),
                                                 ("Messages", "com.apple.MobileSMS", ""), ("Fake Editor", "com.example.fakeeditor", ""),
                                                 (cApp, cBundle, "https://x.com/home"), ("Mail", "com.apple.mail", "")]
    for i in 0..<20_000 {
        let (name, bundle, url) = heavyApps[(i / 50) % heavyApps.count]
        let kind = i % 10 == 9 ? "mouse.click" : "window.changed"
        heavy.append(agentAction("h\(i)", Double(i) * 2, kind: kind, app: name, bundle: bundle, title: "Fake heavy title \((i / 300) % 40) - Google Docs", url: url))
    }
    let clock = Date()
    let heavyItems = AgentItems.items(AgentDayInput(day: agentDay, timezone: agentZone, actions: heavy), policy: policyOn, now: agentNow)
    let seconds = Date().timeIntervalSince(clock)
    print("BENCH: agent items for 20000 rows: \(String(format: "%.3f", seconds)) s, \(heavyItems.count) items")
    try check(seconds < 5 && !heavyItems.isEmpty && heavyItems.count < 400, "agent items: a 20,000-row day is items in one pass (\(String(format: "%.2f", seconds)) s)")
    // Empty and odd input.
    try check(AgentItems.items(AgentDayInput(day: agentDay, timezone: agentZone, actions: []), policy: policyOn, now: agentNow).isEmpty
              && AgentItems.items(AgentDayInput(day: agentDay, timezone: agentZone, actions: actions.filter { noiseIDs.contains($0.id) }), policy: policyOn, now: agentNow).isEmpty,
              "agent items: no rows, or noise only, is no items")
}

private extension Array {
    /// A fixed reordering (reversed halves), so the checks prove order independence without randomness.
    func shuffledDeterministically() -> [Element] {
        let half = count / 2
        return Array(self[half...].reversed()) + Array(self[..<half].reversed())
    }
}
