// claude/dayeval-1005: the day review's quality on six SYNTHETIC personas whose apps are not the owner's (a student, an
// engineer, a designer, a sales lead, a writer, a light user): Canvas, Google Docs, Quizlet, VS Code, Linear, Slack,
// Figma, Notion, Zoom, Salesforce, Outlook, Teams, Excel, Word, Scrivener, Gmail, WhatsApp, Telegram, Signal, Messages.
// SYNTHETIC ONLY: fake people, fake titles, fake sites, a scratch history under $TMPDIR (or DAY_REVIEW_ROOT) seeded through
// the normal store. No app, window, permission, recording, Keychain, network or model (clauses stay empty: this measures
// the code's part of the card, which is all of it when the writer is off or has nothing to add).
//
// Each persona is built twice: with no DayReviewOptions (the card before claude/dayeval-1005) and with the default
// (`DayReviewOptions.recommended`). Cards are written as JSON to DAY_REVIEW_EVAL_OUT (default $TMPDIR/day-review-eval)
// with the personas' reference file; scripts/day-review-eval.py scores them (the runner step gates the default's score).
// The checks here pin what must hold for anyone's day, whatever the score.
import Foundation
import MemoryCore
import PrivacyPolicy

@main @MainActor enum DayReviewEvalChecks {
    static var failures = 0, passes = 0
    static func check(_ ok: Bool, _ name: String, _ got: @autoclosure () -> String = "") {
        if ok { passes += 1; print("PASS " + name) } else {
            failures += 1
            fflush(stdout)
            FileHandle.standardError.write(Data(("FAIL: " + name + (got().isEmpty ? "" : " (got: " + got() + ")") + "\n").utf8))
        }
    }

    nonisolated static let zone = "America/Chicago"
    nonisolated static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }
    nonisolated static func date(_ day: Int, _ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 11, day: day, hour: h, minute: m, second: s))!
    }
    nonisolated static func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d) }
    nonisolated static func key(_ d: Date) -> String { try! DayScope.key(d, timezone: zone) }

    final class Fixture {
        let store: MemoryStore
        var n = 0
        init(_ name: String) throws {
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DAY_REVIEW_ROOT"] ?? NSTemporaryDirectory())
            let home = root.appendingPathComponent("day-review-eval-" + name + "-" + UUID().uuidString.prefix(8))
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
            var policy = try store.policy(); policy.captureText = true; policy.typedConsentVersion = 1
            try store.updatePolicy(policy, now: DayReviewEvalChecks.date(1, 8, 0))
            try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore())); try store.acceptSafeTyping(); try store.setUpTypedVault()
        }
        /// A window used for `minutes`: opened, then a click every 20 s.
        func window(_ app: (String, String), _ title: String, url: String = "", page: String? = nil, at start: Date, minutes: Double) throws {
            var at = start, first = true
            let stop = start.addingTimeInterval(minutes * 60)
            while at < stop {
                n += 1
                var e = Evidence(id: String(format: "de-%05d", n), at: DayReviewEvalChecks.iso(at), kind: first ? "window.changed" : "mouse.click",
                                 app: app.0, bundle: app.1, title: title, url: url, synthetic: true)
                e.page = page
                first = false
                _ = try store.ingest(e, now: at.addingTimeInterval(1))
                at = at.addingTimeInterval(20)
            }
        }
        /// A typed row of fake words with its send facts (a public build refuses Messages rows; that is fine here).
        func typed(_ app: (String, String), _ title: String, at: Date, words: String, surface: String, to: String? = nil, sent: Bool = true, url: String = "") throws {
            n += 1
            var e = Evidence(id: String(format: "de-%05d", n), at: DayReviewEvalChecks.iso(at), kind: "keyboard.text_input", app: app.0, bundle: app.1, title: title,
                             url: url, text: words, synthetic: true)
            var unit = TypedUnitProvenance(runID: "run-\(n)", part: 1, sealReason: "submit", startedAt: DayReviewEvalChecks.iso(at.addingTimeInterval(-20)),
                                           keys: words.count, edits: 0, withheld: 0)
            unit.surface = surface; unit.field = "message"; unit.send = sent ? "detected" : "unknown"; unit.to = to
            unit.version = TypedUnitProvenance.sendFactsVersion
            e.captureProvenance = NativeCaptureProvenance(policyRevision: "r", classifierVersion: "sensitive-typing/v2+typed-scrub/v1", windowID: "w", focusID: "f",
                                                          checkedAt: DayReviewEvalChecks.iso(at), generation: 1, unit: unit)
            _ = try store.ingest(e, now: at.addingTimeInterval(1))
        }
    }

    // Apps (name, bundle id) a typical Mac has that the owner's does not.
    static let chrome = ("Google Chrome", "com.google.Chrome"), safari = ("Safari", "com.apple.Safari")
    static let vscode = ("Code", "com.microsoft.VSCode"), slack = ("Slack", "com.tinyspeck.slackmacgap"), linear = ("Linear", "com.linear")
    static let figma = ("Figma", "com.figma.Desktop"), notion = ("Notion", "notion.id"), zoom = ("zoom.us", "us.zoom.xos")
    static let outlook = ("Microsoft Outlook", "com.microsoft.Outlook"), teams = ("Microsoft Teams", "com.microsoft.teams2")
    static let excel = ("Microsoft Excel", "com.microsoft.Excel"), word = ("Microsoft Word", "com.microsoft.Word")
    static let scrivener = ("Scrivener 3", "com.literatureandlatte.scrivener3"), notes = ("Notes", "com.apple.Notes")
    static let whatsapp = ("WhatsApp", "net.whatsapp.WhatsApp"), telegram = ("Telegram", "ru.keepcoder.Telegram")
    static let signal = ("Signal", "org.whispersystems.signal-desktop"), messages = ("Messages", "com.apple.MobileSMS")
    static let spotify = ("Spotify", "com.spotify.client"), photos = ("Photos", "com.apple.Photos")

    struct Persona {
        let id: String
        let day: Int
        /// The reference: projects by effort (aliases a line may name; detail words a good line gives) and the people texted.
        let projects: [[String: Any]]
        let people: [String]
        let seed: (Fixture, Int) throws -> Void
        /// What no card for this day may say, and what it must (lowercased substrings).
        let never: [String]
        var must: [String] = []
    }

    static func project(_ id: String, _ weight: Double, _ aliases: [String], _ detail: [String] = []) -> [String: Any] {
        ["id": id, "weight": weight, "aliases": aliases, "detail": detail]
    }

    static let personas: [Persona] = [
        Persona(id: "student", day: 2, projects: [project("problem-set", 0.45, ["problem set", "canvas"], ["problem set 5"]),
                                                  project("lab-report", 0.35, ["lab report"]), project("quizlet", 0.2, ["quizlet", "unit 3"])],
                people: ["Priya Shah"], seed: { f, d in
            try f.window(chrome, "Problem Set 5: Eigenvalues", url: "https://canvas.lakeview.edu", page: "https://canvas.lakeview.edu/courses/12/assignments/5",
                         at: date(d, 9, 0), minutes: 55)
            try f.window(chrome, "Lab Report Draft - Google Docs", url: "https://docs.google.com", page: "https://docs.google.com/document/d/fixture1/edit",
                         at: date(d, 10, 0), minutes: 45)
            try f.window(chrome, "Chem Unit 3 Flashcards | Quizlet", url: "https://quizlet.com", page: "https://quizlet.com/fixture/chem-unit-3",
                         at: date(d, 11, 0), minutes: 20)
            try f.window(chrome, "Why do eigenvectors matter? - YouTube", url: "https://www.youtube.com", page: "https://www.youtube.com/watch?v=fixture02",
                         at: date(d, 13, 0), minutes: 18)
            try f.window(whatsapp, "Priya Shah", at: date(d, 13, 20), minutes: 8)
            try f.window(chrome, "Instagram", url: "https://www.instagram.com", page: "https://www.instagram.com/", at: date(d, 13, 30), minutes: 12)
            try f.window(spotify, "Spotify", at: date(d, 13, 45), minutes: 5)
            try f.window(chrome, "Microsoft Copilot", url: "https://copilot.microsoft.com", page: "https://copilot.microsoft.com/chats/fixture", at: date(d, 14, 0), minutes: 12)
            try f.window(chrome, "Problem Set 5: Eigenvalues", url: "https://canvas.lakeview.edu", page: "https://canvas.lakeview.edu/courses/12/assignments/5",
                         at: date(d, 15, 0), minutes: 30)
        }, never: ["worked on texts", "used spotify", "asked chatgpt", "used chatgpt"]),
        Persona(id: "engineer", day: 3, projects: [project("atlas", 0.6, ["atlas"], ["router", "rate limiter", "pull request"]),
                                                   project("linear", 0.25, ["rate limiter", "atl-212"]), project("slack", 0.15, ["slack", "#atlas-dev"])],
                people: ["Leo Park"], seed: { f, d in
            try f.window(vscode, "router.ts — atlas-api", at: date(d, 9, 0), minutes: 70)
            try f.window(chrome, "Add rate limiter by dkim · Pull Request #77 · northwind/atlas-api", url: "https://github.com",
                         page: "https://github.com/northwind/atlas-api/pull/77", at: date(d, 10, 15), minutes: 15)
            try f.window(linear, "ATL-212 Rate limiter rollout", at: date(d, 10, 35), minutes: 20)
            try f.window(slack, "atlas-dev (Channel) - Northwind - Slack", at: date(d, 11, 0), minutes: 15)
            try f.window(vscode, "limiter.test.ts — atlas-api", at: date(d, 13, 0), minutes: 60)
            try f.window(telegram, "Leo Park", at: date(d, 14, 5), minutes: 6)
            try f.window(chrome, "Hacker News", url: "https://news.ycombinator.com", page: "https://news.ycombinator.com/", at: date(d, 14, 15), minutes: 10)
        }, never: ["worked on texts", "telegram with", "atlasapi"], must: ["atlas-api"]),
        Persona(id: "designer", day: 4, projects: [project("checkout", 0.6, ["checkout"], ["redesign"]), project("onboarding", 0.25, ["onboarding"]),
                                                   project("crit", 0.15, ["crit"])],
                people: ["Sam Ortiz"], seed: { f, d in
            try f.window(figma, "Checkout Redesign – Figma", at: date(d, 9, 0), minutes: 100)
            try f.window(notion, "Design Crit Notes", at: date(d, 10, 45), minutes: 15)
            try f.window(zoom, "Zoom Meeting - Design Crit", at: date(d, 11, 0), minutes: 30)
            try f.window(figma, "Onboarding v2 – Figma", at: date(d, 13, 0), minutes: 35)
            try f.window(chrome, "Pinterest", url: "https://www.pinterest.com", page: "https://www.pinterest.com/", at: date(d, 13, 40), minutes: 12)
            try f.window(messages, "Sam Ortiz", at: date(d, 14, 0), minutes: 5)
            try f.window(figma, "Checkout Redesign – Figma", at: date(d, 15, 0), minutes: 40)
        }, never: ["worked on texts", "used figma"]),
        Persona(id: "sales", day: 5, projects: [project("globex", 0.5, ["globex"], ["renewal"]), project("forecast", 0.3, ["forecast"]),
                                                project("pipeline", 0.2, ["pipeline"])],
                people: ["Dana Wells"], seed: { f, d in
            try f.window(chrome, "Globex Renewal | Opportunity | Salesforce", url: "https://acme.lightning.force.com",
                         page: "https://acme.lightning.force.com/lightning/r/Opportunity/fixture/view", at: date(d, 9, 0), minutes: 50)
            try f.window(outlook, "Re: Globex renewal pricing", at: date(d, 9, 55), minutes: 20)
            try f.window(excel, "Q4 Forecast.xlsx", at: date(d, 10, 20), minutes: 40)
            try f.window(teams, "Meeting | Pipeline Review | Microsoft Teams", at: date(d, 11, 0), minutes: 30)
            try f.window(chrome, "LinkedIn", url: "https://www.linkedin.com", page: "https://www.linkedin.com/feed/", at: date(d, 12, 0), minutes: 10)
            try f.window(whatsapp, "Dana Wells", at: date(d, 12, 15), minutes: 5)
            try f.window(chrome, "Globex Renewal | Opportunity | Salesforce", url: "https://acme.lightning.force.com",
                         page: "https://acme.lightning.force.com/lightning/r/Opportunity/fixture/view", at: date(d, 14, 0), minutes: 30)
        }, never: ["worked on texts", "used microsoft teams", "on globex renewal"], must: ["joined pipeline review", "on salesforce"]),
        Persona(id: "writer", day: 6, projects: [project("chapter", 0.7, ["chapter 7", "lighthouse"]), project("research", 0.3, ["fresnel"])],
                people: ["Mira Cole"], seed: { f, d in
            try f.window(word, "Chapter 7 - The Lighthouse.docx", at: date(d, 8, 30), minutes: 110)
            try f.window(chrome, "Fresnel lens - Wikipedia", url: "https://en.wikipedia.org", page: "https://en.wikipedia.org/wiki/Fresnel_lens",
                         at: date(d, 10, 25), minutes: 15)
            try f.window(scrivener, "The Lighthouse — Scrivener", at: date(d, 11, 0), minutes: 30)
            try f.window(notes, "Ideas for chapter 8", at: date(d, 11, 35), minutes: 10)
            try f.window(signal, "Mira Cole", at: date(d, 12, 0), minutes: 5)
            try f.window(chrome, "Inbox (3) - writer@example.com - Gmail", url: "https://mail.google.com", page: "https://mail.google.com/mail/u/0/#inbox",
                         at: date(d, 12, 10), minutes: 10)
        }, never: ["worked on texts"]),
        Persona(id: "light", day: 7, projects: [], people: ["Mom", "Family"], seed: { f, d in
            try f.window(safari, "Lighthouse restoration documentary - YouTube", url: "https://www.youtube.com", page: "https://www.youtube.com/watch?v=fixture03",
                         at: date(d, 19, 0), minutes: 35)
            try f.window(messages, "Mom", at: date(d, 19, 40), minutes: 8)
            try f.window(whatsapp, "Family", at: date(d, 19, 50), minutes: 8)
            try f.window(safari, "Amazon.com: Your Orders", url: "https://www.amazon.com", page: "https://www.amazon.com/gp/your-account/order-history",
                         at: date(d, 20, 0), minutes: 8)
            try f.window(photos, "Photos", at: date(d, 20, 10), minutes: 10)
            try f.window(safari, "Instagram • Chats", url: "https://www.instagram.com", page: "https://www.instagram.com/direct/inbox/", at: date(d, 20, 25), minutes: 6)
        }, never: ["worked on texts", "used photos", "read instagram"]),
    ]

    /// One card as the eval script reads it (the same shape the private real-day replay writes).
    static func card(_ facts: DayReviewFacts, options: DayReviewOptions) -> [String: Any] {
        var quotes = [String: String]()
        for id in facts.quoteIDs { quotes[id] = "«q»" }
        let groups = DayReview.assemble(facts, quotes: quotes, options: options)
        var bullets = [[String: Any]]()
        for (gi, g) in groups.enumerated() {
            for b in g.bullets {
                let t = facts.threads.first { $0.key == b.thread }
                let cat = b.thread == "texting" ? "personal" : b.id.hasPrefix("leftoff") ? "leftoff" : t?.rankCategory.rawValue ?? ""
                bullets.append(["group": gi, "thread": b.thread, "kind": t?.kind ?? "", "category": cat, "lead": b.lead, "link": b.link?.title ?? NSNull(),
                                "rest": b.rest ?? NSNull(), "quote": b.quote != nil, "clause": false, "moments": b.moments, "text": b.text])
            }
        }
        let threads: [[String: Any]] = facts.threads.map { ["key": $0.key, "name": $0.name, "kind": $0.kind, "category": $0.rankCategory.rawValue] }
        return ["day": facts.day, "snapshots": [["at": "24:00", "bullets": bullets, "threads": threads]]]
    }

    static func main() async throws {
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DAY_REVIEW_EVAL_OUT"] ?? (NSTemporaryDirectory() + "day-review-eval"))
        try? FileManager.default.removeItem(at: out)
        var refs = [String: Any]()
        let variants: [(String, DayReviewOptions)] = [("baseline", []), ("default", DayReview.options)]
        let saved = DayReview.options
        for (label, options) in variants {
            let dir = out.appendingPathComponent(label)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            DayReview.options = options
            for p in personas {
                let f = try Fixture(p.id + "-" + label)
                try p.seed(f, p.day)
                let end = date(p.day, 23, 30)
                guard let facts = try f.store.dayLevels(day: key(end), timezone: zone, now: end).review else {
                    check(false, "\(label) \(p.id): a review"); continue
                }
                let c = card(facts, options: options)
                try JSONSerialization.data(withJSONObject: c, options: [.sortedKeys, .prettyPrinted]).write(to: dir.appendingPathComponent(p.id + ".json"))
                refs[p.id] = ["split": "synthetic", "projects": p.projects, "people": p.people]
                guard label == "default" else { continue }
                // What must hold for anyone's day with the default card.
                let bullets = ((c["snapshots"] as! [[String: Any]])[0]["bullets"] as! [[String: Any]])
                let texts = bullets.map { ($0["text"] as! String).lowercased() }
                check(!texts.isEmpty, "\(p.id): the card is not empty")
                for bad in p.never { check(!texts.contains { $0.contains(bad) }, "\(p.id): never \"\(bad)\"", texts.joined(separator: " | ")) }
                if p.id == "student" {
                    let keys = ((c["snapshots"] as! [[String: Any]])[0]["threads"] as! [[String: Any]]).map { $0["key"] as! String }
                    check(keys.contains("ai:copilot"), "student: Copilot on the web is an AI app of its own", keys.joined(separator: ","))
                }
                for good in p.must { check(texts.contains { $0.contains(good) }, "\(p.id): says \"\(good)\"", texts.joined(separator: " | ")) }
                let personal = bullets.filter { ($0["category"] as! String) == "personal" }
                check(personal.count <= 1, "\(p.id): one texting line at most", "\(personal.count)")
                for person in p.people {
                    check(personal.contains { ($0["text"] as! String).contains(person) }, "\(p.id): the texting line names \(person)",
                          personal.map { $0["text"] as! String }.joined(separator: " | "))
                }
                check(!personal.contains { $0["quote"] as! Bool }, "\(p.id): no quote on the texting line")
                check(bullets.allSatisfy { !($0["moments"] as! [String]).isEmpty }, "\(p.id): every line carries its moments")
                check(texts.count <= DayReview.lineBudget + 1, "\(p.id): at most \(DayReview.lineBudget + 1) lines", "\(texts.count)")
                // Work first: no work line after a browsing or personal one.
                let order = bullets.map { ["work": 0, "leftoff": 0, "browsing": 1, "personal": 2][$0["category"] as! String] ?? 1 }
                check(zip(order, order.dropFirst()).allSatisfy { $0 <= $1 }, "\(p.id): work, then browsing, then texting", "\(order)")
                if let main = p.projects.first, let aliases = main["aliases"] as? [String] {
                    check(texts.prefix(2).contains { t in aliases.contains { t.contains($0) } }, "\(p.id): the main project is in the first two lines",
                          texts.joined(separator: " | "))
                }
            }
        }
        DayReview.options = saved
        try JSONSerialization.data(withJSONObject: refs, options: [.sortedKeys, .prettyPrinted]).write(to: out.appendingPathComponent("refs.json"))
        // The work-or-not lists, for apps and sites the owner never uses.
        for (host, page) in [("canvas.lakeview.edu", "Problem Set 5"), ("acme.lightning.force.com", "Globex Renewal"), ("linear.app", "ATL-212"),
                             ("www.figma.com", "Checkout Redesign"), ("docs.google.com", "Lab Report Draft")] {
            check(DayReview.category(kind: "site", key: "site:" + host + "|" + page, channel: nil, options: .recommended) == .work, "work site: \(host)")
        }
        for app in ["Figma", "Notion", "Linear", "Microsoft Word", "Microsoft Excel", "Code", "Slack", "Microsoft Outlook"] {
            check(DayReview.category(kind: "app", key: "app:" + app.lowercased(), channel: nil, name: app, options: .recommended) == .work, "work app: \(app)")
        }
        // Where typing lands for chat, email, writing and AI apps past the owner's own.
        for (bundle, want) in [("ru.keepcoder.Telegram", "chat"), ("org.whispersystems.signal-desktop", "chat"), ("com.microsoft.teams2", "chat"),
                               ("com.facebook.archon", "chat"), ("com.readdle.SparkDesktop", "email"), ("com.superhuman.electron", "email"),
                               ("com.microsoft.Word", "writing"), ("net.shinyfrog.bear", "writing"), ("com.ulyssesapp.mac", "writing")] {
            check(SendRules.surface(bundle: bundle) == want, "surface: \(bundle) is \(want)", SendRules.surface(bundle: bundle))
        }
        for host in ["copilot.microsoft.com", "chat.mistral.ai", "poe.com", "grok.com", "chat.deepseek.com"] {
            check(SendRules.surface(bundle: "com.google.Chrome", host: host) == "ai" && SendRules.aiName(bundle: "com.google.Chrome", host: host) != nil,
                  "surface: \(host) is an AI app")
        }
        print("cards: " + out.path)
        print("day-review-eval-checks: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
