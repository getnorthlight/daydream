// SYNTHETIC ONLY. A made-up day for the README pictures: Riley, the founder of a made-up app "Tallybird", on a
// Tuesday. Every name, title and typed word below is invented. Rows go through the normal store (typed rows through an
// in-memory key, never the Keychain); notes and levels go through the normal core checks.
import Foundation
@testable import MemoryCore

enum SampleDay {
    static let zone = "America/Los_Angeles"
    static let tz = TimeZone(identifier: zone)!
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = tz; return c }
    static let dayKey = "2026-09-29"
    static func at(_ h: Int, _ m: Int, _ s: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: h, minute: m, second: s))! }
    static let clock = at(17, 10)

    struct Note { var ids: [String]; var title: String; var bullets: [(String, [String], String)] }

    static func rows() -> (rows: [[String: Any]], notes: [Note], typed: [String: String]) {
        var rows = [[String: Any]](), counter = 0, notes = [Note](), typedWords = [String: String]()
        func stamp(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; f.timeZone = TimeZone(identifier: "UTC"); return f.string(from: d) }
        func time(_ hm: String, plus: Int = 0) -> Date {
            let p = hm.split(separator: ":").compactMap { Int($0) }
            return at(p[0], p[1]).addingTimeInterval(TimeInterval(plus))
        }
        func nextID() -> String { counter += 1; return String(format: "rdm-%04d", counter) }
        func row(_ kind: String, _ when: Date, _ app: String, _ bundle: String, _ title: String, _ url: String) -> String {
            let id = nextID()
            rows.append(["id": id, "at": stamp(when), "kind": kind, "app": app, "bundle": bundle, "title": title, "url": url, "text": "",
                         "secure": false, "privateWindow": false, "synthetic": true])
            return id
        }
        func stretch(_ app: (String, String), _ title: String, _ url: String, _ from: String, _ minutes: Int) -> [String] {
            let start = time(from)
            var ids = [row("window.changed", start, app.0, app.1, title, url), row("mouse.click", start.addingTimeInterval(10), app.0, app.1, title, url)]
            var s = 120
            while s < minutes * 60 { ids.append(row("window.observed", start.addingTimeInterval(TimeInterval(s)), app.0, app.1, title, url)); s += 120 }
            return ids
        }
        func typed(_ app: (String, String), _ title: String, _ from: String, _ seconds: Int, surface: String, to: String?, words: String, url: String = "") -> [String] {
            let when = time(from, plus: seconds), id = nextID(), send = to != nil || surface == "code"
            var unit: [String: Any] = ["part": 1, "runID": "rdm-run-\(counter)", "sealReason": send ? "submit" : "idle", "send": send ? "detected" : "none",
                                       "startedAt": stamp(time(from, plus: max(0, seconds - 40))), "surface": surface, "version": "typed-unit/v3", "withheld": 0,
                                       "keys": NSNull(), "edits": NSNull()]
            if send { unit["sendBy"] = surface == "email" ? "mailSend" : "return" }
            unit["field"] = surface == "text" ? "message" : "textArea"
            if let to { unit["to"] = to }
            rows.append(["id": id, "at": stamp(when), "kind": "keyboard.text_input", "app": app.0, "bundle": app.1, "title": title, "url": url, "text": words,
                         "secure": false, "privateWindow": false, "synthetic": true,
                         "captureProvenance": ["checkedAt": stamp(when), "classifierVersion": "sensitive-typing/v2", "focusID": "f", "generation": 1,
                                               "policyRevision": "synthetic", "unit": unit, "windowID": "w"] as [String: Any]])
            typedWords[id] = words
            var ids = [id]
            if send { ids.append(row("keyboard.submit", when.addingTimeInterval(1), app.0, app.1, title, "")) }
            return ids
        }
        func note(_ title: String, _ ids: [String], _ bullets: [(String, [String], String)]) { notes.append(Note(ids: ids, title: title, bullets: bullets)) }

        let chrome = ("Chrome", "com.google.Chrome"), messages = ("Messages", "com.apple.MobileSMS")
        let claude = ("Claude", "com.anthropic.claudefordesktop"), terminal = ("Terminal", "com.apple.Terminal")
        let shell = "tallybird — zsh — 120×36"

        let pages = ("Pages", "com.apple.Pages"), docTitle = "Tallybird pricing page"
        // 9:00 Claude, about the pricing page copy.
        let chat1 = stretch(claude, "Pricing page copy", "", "09:00", 40)
        let ask1 = typed(claude, "Pricing page copy", "09:00", 200, surface: "ai", to: "Claude",
                         words: "Can you tighten the pricing page intro to two short sentences? Keep the free plan up front.")
        let ask1b = typed(claude, "Pricing page copy", "09:00", 1100, surface: "ai", to: "Claude",
                          words: "What is a friendlier word than seats for the team plan?")
        note("Pricing page copy", chat1 + ask1 + ask1b, [("Asked Claude to tighten the pricing page intro.", ask1, "submitted"),
                                                         ("Asked Claude for a friendlier word for the team plan.", ask1b, "submitted"),
                                                         ("Had the Pricing page copy chat open in Claude.", chat1, "observed")])

        // 9:30 the pricing page draft in Pages.
        let doc = stretch(pages, docTitle, "", "09:40", 24)
        let draft = typed(pages, docTitle, "09:40", 900, surface: "writing", to: nil,
                          words: "Free for one person. Team plans start at five dollars a month per teammate.")
        note("Pricing page draft", doc + draft, [("Wrote the pricing page draft in Pages.", draft, "draft"),
                                                 ("Had the Pricing page draft open in Pages.", doc, "observed")])

        // 10:05 the export tests in Terminal.
        let term = stretch(terminal, shell, "", "10:05", 20)
        let run1 = typed(terminal, shell, "10:05", 60, surface: "code", to: nil, words: "npm run test -- export")
        let run2 = typed(terminal, shell, "10:05", 1100, surface: "code", to: nil, words: "git commit -am \"Fix CSV export dates\"")
        note("Export tests in Terminal", term + run1 + run2, [("Ran the export tests in Terminal.", run1, "submitted"),
                                                              ("Committed the CSV export date fix.", run2, "submitted"),
                                                              ("Had the tallybird folder open in Terminal.", term, "observed")])

        // 10:40 a break: Hacker News and a talk on YouTube.
        let hn = stretch(chrome, "Show HN: A tiny search engine in SQLite | Hacker News", "https://news.ycombinator.com/item?id=1", "10:40", 9)
        note("Show HN: A tiny search engine in SQLite", hn, [("Read a Show HN post about a tiny search engine in SQLite.", hn, "observed")])
        let yt = stretch(chrome, "How great pricing pages are made - YouTube", "https://www.youtube.com/watch?v=sample", "10:50", 24)
        note("How great pricing pages are made", yt, [("Watched How great pricing pages are made on YouTube.", yt, "observed")])

        // 12:20 one text.
        let maya = stretch(messages, "Maya", "", "12:20", 3)
        let mayaSend = typed(messages, "Maya", "12:20", 90, surface: "text", to: "Maya", words: "Running ten late, save me a seat")
        note("Maya in Messages", maya + mayaSend, [("Texted Maya about lunch.", mayaSend, "submitted"), ("Had Messages open with Maya.", maya, "observed")])

        // 1:30 PM Claude and the draft again, then a build.
        let chat3 = stretch(claude, "Pricing page copy", "", "13:30", 25)
        let ask3 = typed(claude, "Pricing page copy", "13:30", 120, surface: "ai", to: "Claude",
                         words: "Write three short FAQ answers for the pricing page.")
        note("Pricing page copy", chat3 + ask3, [("Asked Claude for three FAQ answers for the pricing page.", ask3, "submitted"),
                                                ("Had the Pricing page copy chat open in Claude.", chat3, "observed")])
        let doc2 = stretch(pages, docTitle, "", "13:55", 12)
        let draft2 = typed(pages, docTitle, "13:55", 500, surface: "writing", to: nil,
                           words: "Can I cancel any time? Yes. Your data stays yours and exports in one click.")
        note("Pricing page draft", doc2 + draft2, [("Added FAQ answers to the pricing page draft in Pages.", draft2, "draft"),
                                                   ("Had the Pricing page draft open in Pages.", doc2, "observed")])
        let term2 = stretch(terminal, shell, "", "14:10", 10)
        let run3 = typed(terminal, shell, "14:10", 50, surface: "code", to: nil, words: "npm run build && npm run preview")
        note("Site build in Terminal", term2 + run3, [("Built and previewed the site in Terminal.", run3, "submitted"),
                                                      ("Had the tallybird folder open in Terminal.", term2, "observed")])
        return (rows, notes, typedWords)
    }

    /// Seeds `home` (a new folder) and returns the open store, which holds the typing key in memory.
    static func seed(home: URL) throws -> MemoryStore {
        let (rows, notes, _) = rows()
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        try store.keepNotesAsWritten()
        let first = clock.addingTimeInterval(-3 * 86400)
        var consent = try store.policy(); consent.captureText = true; try store.updatePolicy(consent, now: first)
        try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore()), now: first)
        try store.setUpTypedVault(now: first)
        try store.acceptSafeTyping(now: first)
        var typed = try store.typedTextPolicy()
        typed.retention = .days30
        typed.categories = TypedCategoryChoices(searchAndAI: true, writing: true, code: true, messagesAndEmail: true, otherWebsites: true)
        typed.shareWithSummaries = .localOnly
        _ = try store.updateTypedTextPolicy(typed, confirmed: true, now: first)

        var ingested = 0, refused = 0
        for row in rows {
            let e = try JSONDecoder().decode(Evidence.self, from: JSONSerialization.data(withJSONObject: row))
            let when = ISO8601DateFormatter().date(from: row["at"] as! String)!
            if (try? store.ingest(e, now: when.addingTimeInterval(1))) == true { ingested += 1 } else { refused += 1; print("REFUSED \(e.id) \(e.kind) \(e.app)") }
        }
        print("ingested \(ingested) refused \(refused)")

        var byAction = [String: [Int]]()
        for (i, n) in notes.enumerated() { for a in n.ids { byAction[a, default: []].append(i) } }
        var used = Set<Int>(), model = 0, code = 0
        for m in try store.dayLayers(day: dayKey, timezone: zone, limit: 1, now: clock).activities where m.status != "ready" {
            guard let request = try? store.prepareNote(kind: "activity", day: dayKey, timezone: zone, activityID: m.id, now: clock) else { continue }
            let ids = Set(request.actions.map(\.id))
            var overlap = [Int: Int]()
            for a in ids { for i in byAction[a] ?? [] { overlap[i, default: 0] += 1 } }
            let ranked = overlap.filter { !used.contains($0.key) }.sorted { ($0.value, -$0.key) > ($1.value, -$1.key) }
            var committed = false
            for (i, _) in ranked.prefix(3) {
                let n = notes[i]
                let bullets = n.bullets.filter { !$0.1.isEmpty && Set($0.1).isSubset(of: ids) }.map { NoteBullet(text: $0.0, actionIDs: $0.1, assertion: $0.2) }
                guard !bullets.isEmpty else { continue }
                for attempt in [bullets, bullets.filter { $0.assertion != "submitted" }] where !attempt.isEmpty {
                    do {
                        _ = try store.commitNote(NoteWriterOutput(requestID: request.id, title: n.title, bullets: attempt, generator: "local/sample",
                                                                  generatorVersion: "readme-1"), now: clock)
                        committed = true; break
                    } catch { print("note refused for \(n.title): \(error)") }
                }
                if committed { used.insert(i); model += 1; break }
            }
            if !committed { code += 1; print("no note for moment \(m.id) \(m.subject)") }
        }
        print("notes \(model) missing \(code)")
        var levels = 0
        while levels < 100, let request = try store.levelWork(timezone: zone, now: clock, backfillDays: 2, limit: 1).first {
            let (title, lines) = LevelGrounding.extractive(request)
            _ = try store.commitLevel(request, title: title, lines: lines, generator: LevelWriterVersion.extractive, now: clock)
            levels += 1
        }
        print("levels \(levels)")
        return store
    }
}
