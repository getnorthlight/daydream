// claude/day-review-1003: the Today card's day review (DayReview.swift, DayReviewStore.swift, DayReviewCard.swift).
// SYNTHETIC ONLY: fake people, fake words, a scratch history under $TMPDIR (or DAY_REVIEW_ROOT) seeded through the normal
// store; an in-memory typing key; a fake model. No app, window, permission, recording, Keychain, network or real model.
// Typed words are never printed (bullets print with their quotes masked).
//
// Fixtures: a work-heavy day, a texting-heavy day, a high-stakes single text, an early-morning thin day, a reshuffle
// attempt (hysteresis), a Forget, a model failure; plus a reading-only day, an excluded app, midnight and the clause
// checks. The texting fixtures need Messages typing (the owner build, -D DAYDREAM_OWNER_TYPING); the public build checks
// that no Messages typed row is ever saved there instead.
import Foundation
import SwiftUI
import MemoryCore
import MemoryUI
import CoreIntegration

@main @MainActor enum DayReviewChecks {
    static var failures = 0, passes = 0
    static func check(_ ok: Bool, _ name: String, _ got: @autoclosure () -> String = "") {
        if ok { passes += 1; print("PASS " + name) } else {
            failures += 1
            fflush(stdout)
            FileHandle.standardError.write(Data(("FAIL: " + name + (got().isEmpty ? "" : " (got: " + got() + ")") + "\n").utf8))
        }
    }

    static func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) { check(got == want, name, "\(got)") }

    nonisolated static let zone = "America/Chicago"
    nonisolated static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }
    nonisolated static func date(_ day: Int, _ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 10, day: day, hour: h, minute: m, second: s))!
    }
    nonisolated static func iso(_ d: Date) -> String { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]; return f.string(from: d) }
    nonisolated static func key(_ d: Date) -> String { try! DayScope.key(d, timezone: zone) }

    /// A bullet as one line with its quote masked (never the typed words).
    static func shape(_ b: DayReviewBullet) -> String {
        var c = b; if c.quote != nil { c.quote = "«q»" }; return c.text
    }
    static func shapes(_ g: [DayReviewGroup]) -> [String] { g.flatMap { $0.bullets.map(shape) } }

    // MARK: fixture store

    final class Fixture {
        let store: MemoryStore
        let home: URL
        var n = 0
        init(_ name: String) throws {
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DAY_REVIEW_ROOT"] ?? NSTemporaryDirectory())
            home = root.appendingPathComponent("day-review-" + name + "-" + UUID().uuidString.prefix(8))
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
            var policy = try store.policy(); policy.captureText = true; policy.typedConsentVersion = 1
            try store.updatePolicy(policy, now: DayReviewChecks.date(1, 8, 0))
            try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore())); try store.acceptSafeTyping(); try store.setUpTypedVault()
        }
        /// A window used for `minutes`: opened, then a click every 20 s.
        @discardableResult func window(_ app: String, _ bundle: String, _ title: String, url: String = "", page: String? = nil, at start: Date, minutes: Double) throws -> [String] {
            var ids = [String](), at = start, first = true
            let stop = start.addingTimeInterval(minutes * 60)
            while at < stop {
                n += 1
                var e = Evidence(id: String(format: "dr-%05d", n), at: DayReviewChecks.iso(at), kind: first ? "window.changed" : "mouse.click", app: app, bundle: bundle,
                                 title: title, url: url, synthetic: true)
                e.page = page
                first = false
                if try store.ingest(e, now: at.addingTimeInterval(1)) { ids.append(e.id) }
                at = at.addingTimeInterval(20)
            }
            return ids
        }
        /// A typed row (fake words) sealed with its send facts; nil when the store refused it (a public build's Messages).
        @discardableResult func typed(_ app: String, _ bundle: String, _ title: String, at: Date, words: String, surface: String, field: String = "message",
                                      to: String? = nil, sent: Bool = true, edits: Int = 0, composeSeconds: Double = 20, author: String? = nil, url: String = "") throws -> String? {
            n += 1
            var e = Evidence(id: String(format: "dr-%05d", n), at: DayReviewChecks.iso(at), kind: "keyboard.text_input", app: app, bundle: bundle, title: title,
                             url: url, text: words, synthetic: true)
            var unit = TypedUnitProvenance(runID: "run-\(n)", part: 1, sealReason: "submit", startedAt: DayReviewChecks.iso(at.addingTimeInterval(-composeSeconds)),
                                           keys: words.count + edits, edits: edits, withheld: 0)
            unit.surface = surface; unit.field = field; unit.send = sent ? "detected" : "unknown"; unit.to = to; unit.contextAuthor = author
            unit.version = TypedUnitProvenance.sendFactsVersion
            e.captureProvenance = NativeCaptureProvenance(policyRevision: "r", classifierVersion: "sensitive-typing/v2+typed-scrub/v1", windowID: "w", focusID: "f",
                                                          checkedAt: DayReviewChecks.iso(at), generation: 1, unit: unit)
            return try store.ingest(e, now: at.addingTimeInterval(1)) ? e.id : nil
        }
        /// Code notes for every moment of the day (what the clause writer reads).
        func notes(_ d: Date) throws {
            let day = DayReviewChecks.key(d)
            for m in try store.dayLayers(day: day, timezone: DayReviewChecks.zone, limit: 1, now: d).activities where m.status != "ready" {
                guard let request = try? store.prepareNote(kind: "activity", day: day, timezone: DayReviewChecks.zone, activityID: m.id, now: d) else { continue }
                let app = m.apps.first { !$0.isEmpty } ?? "an app"
                let subject = m.subject.trimmingCharacters(in: .whitespacesAndNewlines)
                let ids = request.actions.filter { $0.kind != "keyboard.text_input" }.map(\.id)
                guard !ids.isEmpty else { continue }
                _ = try? store.commitNote(NoteWriterOutput(requestID: request.id, title: subject.isEmpty ? app : subject,
                                                           bullets: [NoteBullet(text: subject.isEmpty ? "Had \(app) open." : "Worked on \(subject) in \(app).", actionIDs: ids)],
                                                           generator: "code/day-review-fixture", generatorVersion: "1"), now: d)
            }
        }
        func review(_ now: Date) throws -> DayReviewFacts? { try store.dayLevels(day: DayReviewChecks.key(now), timezone: DayReviewChecks.zone, now: now).review }
        func forget(_ start: Date, _ end: Date, now: Date) throws {
            let preview = try store.prepareDeletion(scope: .range(start: start, end: end, timezone: DayReviewChecks.zone), now: now)
            _ = try store.executeDeletion(previewID: preview.id, confirmed: true, now: now)
        }
    }

    static let ghostty = ("Ghostty", "com.mitchellh.ghostty"), terminal = ("Terminal", "com.apple.Terminal"), chrome = ("Google Chrome", "com.google.Chrome")
    static let messages = ("Messages", "com.apple.MobileSMS"), slack = ("Slack", "com.tinyspeck.slackmacgap")

    /// A work-heavy morning on DayDream: Ghostty and Terminal in ~/daydream, its GitHub PR and repo, then a YouTube video
    /// and an X post read.
    static func seedWork(_ f: Fixture, day: Int, from: Int = 9) throws {
        try f.window(ghostty.0, ghostty.1, "~/daydream", at: date(day, from, 0), minutes: 50)
        try f.window(chrome.0, chrome.1, "Fix Messages drafts by samrivera · Pull Request #12 · acme/daydream", url: "https://github.com",
                     page: "https://github.com/acme/daydream/pull/12", at: date(day, from, 52), minutes: 12)
        try f.window(terminal.0, terminal.1, "~/daydream — swift build", at: date(day, from + 1, 6), minutes: 40)
        try f.window(ghostty.0, ghostty.1, "~/daydream", at: date(day, from + 1, 48), minutes: 45)
        try f.window(chrome.0, chrome.1, "How do lighthouse lenses work? - YouTube", url: "https://www.youtube.com",
                     page: "https://www.youtube.com/watch?v=fixture01", at: date(day, from + 2, 40), minutes: 14)
        try f.window(chrome.0, chrome.1, "Ada on X: \"New models soon\" / X", url: "https://x.com", page: "https://x.com/fixture/status/1",
                     at: date(day, from + 2, 56), minutes: 4)
    }

    static func main() async throws {
        // claude/dayeval-1005: the default card (`DayReviewOptions.recommended`): projects, filler dropped, one texting line
        // with names only, work sites, six lines at most, the fact-packet writer with typed facts on this Mac. Personas with
        // other people's apps are scripts/day-review-eval-checks.swift.
        check(DayReview.options == .recommended && !DayReview.options.contains(.leftOff) && !DayReview.options.contains(.textingQuote),
              "options: the default is the recommended set: no left-off line, no quote on the texting line")
        pure()
        plainWords()
        hysteresis()
        clauses()
        try await stores()
        try await bench()
        print("day-review-checks: \(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: pure values

    static func item(_ id: String, _ lead: String, plain: String? = nil, colon: Bool = false, link: DayReviewLink? = nil, tail: String? = nil, clause: String? = nil,
                     quote: String? = nil, always: Bool = false, score: Double = 1) -> DayReviewItem {
        DayReviewItem(id: id, lead: lead, plainLead: plain, colon: colon, link: link, tail: tail, clauseKey: clause, quote: quote, quoteAlways: always, score: score, moments: ["m-" + id])
    }
    static func thread(_ key: String, _ kind: String, _ score: Double, _ items: [DayReviewItem]) -> DayReviewThread {
        DayReviewThread(key: key, name: key, kind: kind, seconds: 600, words: 0, personSends: 0, asks: 0, sendHours: 0, stakes: [], score: score, items: items, moments: [])
    }

    static func pure() {
        // Scores: a send to a person outweighs ten minutes; steady texting and high stakes boost a person.
        let tenMinutes = DayReview.score(seconds: 600, words: 0, personSends: 0, asks: 0, sendHours: 0, stakes: 0)
        let oneText = DayReview.score(seconds: 0, words: 10, personSends: 1, asks: 0, sendHours: 1, stakes: 0)
        check(oneText > tenMinutes, "score: one text (\(oneText)) outweighs ten minutes (\(tenMinutes))")
        let steady = DayReview.score(seconds: 600, words: 100, personSends: 6, asks: 0, sendHours: 4, stakes: 0)
        let bunched = DayReview.score(seconds: 600, words: 100, personSends: 6, asks: 0, sendHours: 1, stakes: 0)
        check(steady >= bunched * 1.4, "score: texting across several separate hours is boosted (\(steady) vs \(bunched))")
        check(DayReview.score(seconds: 0, words: 0, personSends: 1, asks: 0, sendHours: 0, stakes: 9) == DayReview.personSend + DayReview.stakesCap,
              "score: high-stakes boosts are capped")
        let s = DayReview.stakes(words: 60, keys: 400, edits: 120, parts: 1, composeSeconds: 300, localHour: 23, firstContact: true)
        check(Set(s) == Set(DayReview.Stake.allCases), "stakes: long, rewritten, paused, first contact, late night (\(s))")
        check(DayReview.stakes(words: 5, keys: 30, edits: 0, parts: 1, composeSeconds: 10, localHour: 14, firstContact: false).isEmpty, "stakes: a quick text has none")

        // Rank groups 3 / 2 / 1 (claude/dayeval-1005: six lines at most, `DayReview.lineBudget`).
        let five = (0..<5).map { t in thread("t\(t)", "project", Double(100 - t * 10), (0..<4).map { i in item("t\(t)i\(i)", "Did thing \(t).\(i)", score: Double(10 - i)) }) }
        let facts = DayReviewFacts(day: "2026-10-03", threads: five, clauses: [:], activeSeconds: 3600, personSends: 0)
        let groups = DayReview.assemble(facts)
        check(groups.map(\.bullets.count) == [3, 2, 1] && groups.last?.id == "rest", "assemble: 3 / 2 / 1 bullets, 6 lines at most (\(groups.map(\.bullets.count)))")
        check(groups.flatMap(\.bullets).map(\.thread) == ["t0", "t0", "t0", "t1", "t1", "t2"], "assemble: groups follow the thread order")
        let seven = DayReview.assemble(facts, options: DayReview.options.subtracting(.lineBudget))
        check(seven.map(\.bullets.count) == [3, 2, 2], "assemble: with no line budget, 3 / 2 / 1+1 bullets, 7 at most (\(seven.map(\.bullets.count)))")
        let thin = DayReview.assemble(DayReviewFacts(day: "d", threads: [thread("a", "web", 3, [item("a1", "Read", tail: "example.com")])], clauses: [:], activeSeconds: 120, personSends: 0))
        check(shapes(thin) == ["Read example.com."], "assemble: a thin day has fewer bullets (\(shapes(thin)))")
        let dup = DayReview.assemble(DayReviewFacts(day: "d", threads: [thread("a", "web", 3, [item("a1", "Read", tail: "x"), item("a2", "Read", tail: "x")])], clauses: [:], activeSeconds: 0, personSends: 0))
        check(dup.flatMap(\.bullets).count == 1, "assemble: the same line twice shows once")

        // The approved shapes.
        let words = ["q1": "fixture words one", "q2": "fixture words two", "q3": "fixture reply"]
        var jamie = thread("person:jamie lin", "person", 50, [
            item("g#said", "Told Jamie Lin", plain: "Texted Jamie Lin", clause: "person:jamie lin", quote: "q1"),
            item("g#quote", "Texted Jamie Lin", quote: "q2", always: true)])
        jamie.person = "Jamie Lin"; jamie.personSends = 3
        let work = thread("project:daydream", "project", 90, [item("code", "Worked on DayDream", colon: true, tail: "in Ghostty", clause: "code:daydream")])
        let ada = thread("social:x", "social", 20, [item("x1", "Replied to", link: DayReviewLink(title: "Ada's post", url: "https://x.com/t/status/1"), tail: "on X",
                                                         clause: "social:x#x1", quote: "q3", always: true)])
        let yt = thread("video:youtube.com", "video", 10, [item("v1", "Watched", link: DayReviewLink(title: "\u{201C}How do lighthouse lenses work?\u{201D}", url: "https://www.youtube.com/watch?v=1"), tail: "on YouTube")])
        var f = DayReviewFacts(day: "d", threads: [work, jamie, ada, yt], clauses: [:], activeSeconds: 7200, personSends: 3)
        var b = DayReview.assemble(f, quotes: words).flatMap(\.bullets)
        check(b.map(\.text) == ["Worked on DayDream in Ghostty.", "Replied to Ada's post on X: \u{201C}fixture reply\u{201D}",
                                "Watched \u{201C}How do lighthouse lenses work?\u{201D} on YouTube.", "Texted Jamie Lin."],
              "bullets: code's own words before any clause, the texting line last with names only (\(b.map(shape)))")
        check(b.last?.moments == ["m-g#said", "m-g#quote"],
              "bullets: the texting line carries its conversations' moments (\(b.last?.moments ?? []))")
        f.clauses = ["code:daydream": "Messages sends saved as drafts and the Ghostty spinner", "person:jamie lin": "you and friends are going to ZUX tomorrow",
                     "social:x#x1": "about upcoming models"]
        b = DayReview.assemble(f, quotes: words).flatMap(\.bullets)
        // claude/today-rank-1005: work first, then browsing, then one line for the conversation.
        check(b.map(shape) == ["Worked on DayDream: Messages sends saved as drafts and the Ghostty spinner.", "Replied to Ada's post about upcoming models: \u{201C}«q»\u{201D}",
                               "Watched \u{201C}How do lighthouse lenses work?\u{201D} on YouTube.", "Texted Jamie Lin."],
              "bullets: the approved shapes with clauses, work first and the texting line once, last, names only (\(b.map(shape)))")
        check(b.count == 4 && b[0].lead == "Worked on DayDream:" && b[3].lead == "Texted Jamie Lin" && b[3].quote == nil,
              "bullets: a lead (colon after a name before a clause), the texting line never quotes")
        // A day of only the conversation: the texting line, names only (owner 10/05: no quote on a conversation line).
        let alone = DayReview.assemble(DayReviewFacts(day: "d", threads: [jamie], clauses: f.clauses, activeSeconds: 600, personSends: 3), quotes: words).flatMap(\.bullets)
        check(alone.map(shape) == ["Texted Jamie Lin."] && alone.allSatisfy { $0.quote == nil },
              "bullets: with little else, the conversation is still one line with no quote (\(alone.map(shape)))")
        let quoted = DayReview.assemble(DayReviewFacts(day: "d", threads: [jamie], clauses: f.clauses, activeSeconds: 600, personSends: 3), quotes: words,
                                        options: DayReview.options.union(.textingQuote)).flatMap(\.bullets)
        check(quoted.count == 1 && quoted[0].quote != nil, "bullets: the texting quote stays an owner choice, off by default (\(quoted.map(shape)))")
        check(!b.contains { $0.text.contains("~") || $0.text.range(of: #"\b\d+ (min|hr|h)\b"#, options: .regularExpression) != nil || $0.text.contains("Updated") },
              "bullets: no durations, counts, times or Updated line")
        let noWords = DayReview.assemble(f, quotes: [:]).flatMap(\.bullets)
        check(noWords[1].quote == nil && noWords.count == b.count, "bullets: a quote whose words couldn't be opened is left out, the bullet stays")
        // Styled text: bold lead first, the link carries its URL (not bold), the quote italic.
        let a = DayReviewList.attributed(b[1])
        let runs = a.runs.map { (String(a[$0.range].characters), $0.link) }
        check(runs.first?.0 == "Replied to" && runs.contains { $0.0 == "Ada's post" && $0.1?.absoluteString == "https://x.com/t/status/1" }
              && runs.last?.0.hasPrefix("\u{201C}") == true, "card: lead, link with its URL, then the quote in curly quotes")
        noBold()
        askTopics(words)
        ranking()
        // Owner 10/03: a quote shows on one line first (about 80 characters, cut at a word with "…"), all of it expanded.
        let longWords = "fixture reply about the upcoming models and why the evaluation numbers look different from what the launch post claimed"
        var longB = b[1]; longB.quote = longWords
        let short = longB.shortQuote ?? ""
        let kept = String(short.dropLast())
        check(short.count <= DayReview.quoteLine && short.hasSuffix("…") && longWords.hasPrefix(kept)
              && (longWords.dropFirst(kept.count).first.map { $0 == " " } ?? false), "quotes: one line, cut at a word boundary with … (\(short.count) chars)")
        check(longB.expandable && longB.text.contains(short) && longB.fullText.contains(longWords), "quotes: the full text is kept for expanding")
        let folded = String(DayReviewList.attributed(longB).characters), open = String(DayReviewList.attributed(longB, expanded: true).characters)
        check(folded.contains(short) && !folded.contains(longWords) && open.contains(longWords) && open.hasPrefix("Replied to Ada's post"),
              "card: folded shows one line, expanded shows every word, the link stays")
        check(!b[1].expandable && b[1].shortQuote == b[1].quote, "quotes: a short quote shows whole and doesn't expand")
        check(DayReview.oneLine(String(repeating: "x", count: 120)).count == DayReview.quoteLine, "quotes: a quote with no spaces is cut at the limit")
        // Facts never carry the quotes' words when encoded (they are opened in the app only).
        var withQuotes = f; withQuotes.quotes = words
        let data = (try? JSONEncoder().encode(withQuotes)).map { String(decoding: $0, as: UTF8.self) } ?? ""
        check(!data.isEmpty && !data.contains("fixture words") && !data.contains("\"quotes\""), "facts: quotes are never encoded")
    }

    // MARK: claude/today-rank-1005 (owner 10/05): productivity first, conversations once and last

    static func ranking() {
        let cases: [(String, String, String?, String, DayReview.Category)] = [
            ("ai", "app:claude", nil, "", .work), ("code", "code:daydream", nil, "", .work), ("doc", "doc:launch plan", nil, "", .work),
            ("project", "project:daydream", nil, "", .work), ("meeting", "meeting:standup", nil, "", .work), ("pr", "pr:acme/daydream#12", nil, "", .work),
            ("web", "page:docs.google.com|/document/d/x", nil, "", .work), ("web", "site:calendar.google.com", nil, "", .work),
            ("web", "site:canvas.instructure.com", nil, "", .work), ("web", "page:www.notion.so|x", nil, "", .work),
            ("person", "person:sam", "email", "", .work), ("person", "person:#eng", "slack", "", .work), ("person", "person:dana", "teams", "", .work),
            ("app", "app:numbers", nil, "Numbers", .work), ("app", "app:spotify", nil, "Spotify", .browsing),
            ("social", "social:x", nil, "", .browsing), ("video", "video:youtube.com|x", nil, "", .browsing), ("web", "site:example.com", nil, "", .browsing),
            ("person", "person:jamie lin", "texts", "", .personal), ("person", "person:jamie lin", nil, "", .personal), ("person", "person:kai", "chat", "", .personal),
            ("texts", "texts:?", nil, "", .personal), ("chat", "chat:discord|general", nil, "", .personal), ("web", "site:instagram.com", nil, "", .personal),
            ("web", "page:web.whatsapp.com|x", nil, "", .personal)]
        for (kind, key, channel, name, want) in cases {
            equal(DayReview.category(kind: kind, key: key, channel: channel, name: name), want, "rank: \(key)\(channel.map { " (" + $0 + ")" } ?? "") is \(want.rawValue)")
        }
        // An hour of steady texting with high stakes outscores ten minutes in Claude, but ranks below it; browsing between.
        var texting = thread("person:jamie lin", "person", DayReview.score(seconds: 3600, words: 600, personSends: 12, asks: 0, sendHours: 4, stakes: 3),
                             [item("j1", "Told Jamie Lin", plain: "Texted Jamie Lin", clause: "person:jamie lin", quote: "q1"), item("j2", "Texted Jamie Lin", quote: "q2", always: true)])
        texting.person = "Jamie Lin"; texting.personSends = 12
        let claude = thread("app:claude", "ai", DayReview.score(seconds: 600, words: 0, personSends: 0, asks: 1, sendHours: 0, stakes: 0), [item("c1", "Asked Claude")])
        let docs = thread("doc:launch plan", "doc", 30, [item("d1", "Wrote", tail: "Launch plan")])
        let code = thread("code:daydream", "code", 25, [item("k1", "Worked on DayDream", colon: true, tail: "in Ghostty"), item("k2", "Read", tail: "the fixture PR")])
        let x = thread("social:x", "social", 40, [item("x1", "Read", tail: "posts on X")])
        let facts = DayReviewFacts(day: "d", threads: [texting, x, docs, code, claude], clauses: [:], activeSeconds: 7200, personSends: 12)
        let words = ["q1": "fixture text one", "q2": "fixture text two"]
        check(texting.score > claude.score * 10, "rank: the texting's importance score is far above Claude's (\(texting.score) vs \(claude.score))")
        let order = DayReviewStanding.raw(DayReview.rankScores(facts))
        equal(order, ["doc:launch plan", "code:daydream", "app:claude", "social:x", "person:jamie lin"], "rank: work by score, then browsing, then the conversation")
        let b = DayReview.assemble(facts, quotes: words).flatMap(\.bullets)
        check(b.map(\.thread) == ["doc:launch plan", "code:daydream", "code:daydream", "app:claude", "social:x", "texting"],
              "rank: the card shows work first, then browsing, and the texting line once, last (\(b.map(\.thread)))")
        // With room, browsing comes between the work and the conversation.
        let roomy = DayReview.assemble(DayReviewFacts(day: "d", threads: [texting, x, docs, claude], clauses: [:], activeSeconds: 7200, personSends: 12), quotes: words)
        check(roomy.flatMap(\.bullets).map(\.thread) == ["doc:launch plan", "app:claude", "social:x", "texting"],
              "rank: browsing between the work and the conversation (\(roomy.flatMap(\.bullets).map(\.thread)))")
        // Never hidden: with work filling every group, the conversation still takes the last place.
        let more = (0..<6).map { thread("code:p\($0)", "code", Double(50 - $0), [item("p\($0)", "Worked on P\($0)")]) }
        let full = DayReview.assemble(DayReviewFacts(day: "d", threads: more + [texting], clauses: [:], activeSeconds: 7200, personSends: 12), quotes: words).flatMap(\.bullets)
        check(full.last?.thread == "texting" && full.filter { $0.thread == "texting" }.count == 1 && full.count <= DayReview.lineBudget,
              "rank: a conversation is never hidden; it keeps the last place (\(full.map(\.thread)))")
        // Little else (no other thread with ten points): score order, nothing capped.
        let thin = DayReviewFacts(day: "d", threads: [texting, thread("app:claude", "ai", 4, [item("c1", "Asked Claude")])], clauses: [:], activeSeconds: 900, personSends: 12)
        let tb = DayReview.assemble(thin, quotes: words).flatMap(\.bullets)
        check(!DayReview.hasOtherThings(thin) && tb.map(\.thread) == ["texting", "app:claude"],
              "rank: with little else the texting line leads, one line (\(tb.map(\.thread)))")
        // Deterministic: the same facts, the same card.
        check(DayReview.assemble(facts, quotes: words) == DayReview.assemble(facts, quotes: words), "rank: deterministic")
        // An older value with no category reads it from its kind.
        check(thread("person:x", "person", 1, []).rankCategory == .personal && thread("doc:x", "doc", 1, []).rankCategory == .work, "rank: no stored category, from the kind")
    }

    // MARK: claude/today-copy-1004 (owner 10/04): no bold, and never "Asked Claude about Claude"

    /// The card's styled text has no bold run anywhere (lead, link, rest, quote), folded or expanded, and the lead is the
    /// regular system font in the system's own ink (so the light and dark themes keep the same order).
    static func noBold() {
        let size: CGFloat = 13
        let heavy: [Font] = [.system(size: size, weight: .semibold), .system(size: size, weight: .bold), .system(size: size, weight: .medium),
                             .system(size: size, weight: .heavy), .system(size: size).bold()]
        let bullets = [DayReviewBullet(id: "a", thread: "t", lead: "Asked Claude:", link: nil, rest: nil, quote: "fixture words", moments: []),
                       DayReviewBullet(id: "b", thread: "t", lead: "Texted Avery Fixture:", link: nil, rest: nil, quote: "fixture text", moments: []),
                       DayReviewBullet(id: "c", thread: "t", lead: "Read", link: nil, rest: "posts on X", quote: nil, moments: []),
                       DayReviewBullet(id: "d", thread: "t", lead: "Replied to", link: DayReviewLink(title: "Ada's post", url: "https://x.com/t/status/1"),
                                       rest: "on X", quote: "fixture reply", moments: []),
                       DayReviewBullet(id: "e", thread: "t", lead: "Worked on DayDream:", link: nil, rest: "the fixture build", quote: nil, moments: [])]
        for b in bullets {
            for expanded in [false, true] {
                let a = DayReviewList.attributed(b, size: size, expanded: expanded)
                let fonts = a.runs.compactMap(\.font)
                let strong = a.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true }
                check(!fonts.contains { heavy.contains($0) } && !strong, "no bold: \(b.lead) \(expanded ? "expanded" : "folded") has no bold run")
            }
            let a = DayReviewList.attributed(b, size: size)
            let lead = a.runs.first
            check(lead.map { String(a[$0.range].characters) } == b.lead && lead?.font == .system(size: size) && lead?.foregroundColor == .primary,
                  "no bold: \(b.lead) is regular weight in the system ink")
        }
    }

    /// The "about …" of a code line never only says the tool, the app or the person again, and never says nothing.
    static func askTopics(_ words: [String: String]) {
        let ask = ["Claude"] + DayReview.askPlaces
        for (raw, echo, want) in [("Claude", ask, nil), (" claude ", ["Claude"], nil), ("ChatGPT", ["ChatGPT"] + DayReview.askPlaces, nil),
                                  ("CHATGPT", ["ChatGPT"], nil), ("Claude Code", ask, nil), ("New chat", ask, nil), ("", ask, nil), ("  —  ", ask, nil),
                                  ("Jamie Lin", ["Jamie Lin"], nil), ("(no subject)", ["Sam"], nil),
                                  ("DayDream", ask, "DayDream"), ("Claude pricing", ["Claude"], "Claude pricing"), ("Q3 numbers", ["Sam"], "Q3 numbers")]
                as [(String, [String], String?)] {
            check(DayReview.topic(raw, echoing: echo) == want, "about: \"\(raw)\" after \(echo.first ?? "-") -> \(want ?? "no about")",
                  DayReview.topic(raw, echoing: echo) ?? "nil")
        }
        check(DayReview.topic(nil, echoing: ask) == nil, "about: no topic, no about")
        // An ask with no topic: "Asked Claude: “…”", or "Asked Claude." with no words opened; never "about Claude".
        let t = thread("app:claude", "ai", 10, [item("ask", "Asked Claude", clause: "app:claude", quote: "q1")])
        let quoted = DayReview.assemble(DayReviewFacts(day: "d", threads: [t], clauses: [:], activeSeconds: 0, personSends: 0), quotes: words).flatMap(\.bullets)
        let bare = DayReview.assemble(DayReviewFacts(day: "d", threads: [t], clauses: [:], activeSeconds: 0, personSends: 0), quotes: [:]).flatMap(\.bullets)
        check(quoted.map(\.text) == ["Asked Claude: \u{201C}fixture words one\u{201D}"] && bare.map(\.text) == ["Asked Claude."],
              "about: an ask with no topic reads \"Asked Claude: “…”\"", "\(quoted.map(\.text)) \(bare.map(\.text))")
        // The clause writer can't put it back: "about Claude" after "Asked Claude" is refused as the start again.
        let r = DayReviewClauseRequest(day: "2026-10-04", timezone: zone, key: "app:claude", lead: "Asked Claude", name: "Claude", colon: false,
                                       notes: ["Asked Claude how to run the fixture over ssh."], signature: "s0|p0|m1", actionIDs: ["a"], start: "", end: "")
        for raw in ["{\"clause\":\"about Claude\"}", "{\"clause\":\"about Claude and the fixture\"}"] {
            check((try? DayReviewClauses.validate(raw, request: r)) == nil, "about: the clause writer's \(raw) is refused")
        }
        check((try? DayReviewClauses.validate("{\"clause\":\"how to run the fixture over ssh\"}", request: r)) == "how to run the fixture over ssh",
              "about: a clause that says what was asked passes")
    }

    // MARK: hysteresis (reshuffle attempt) and midnight

    static func hysteresis() {
        var s = DayReviewStanding()
        let t0 = date(3, 12, 0)
        check(s.rank(["a": 100, "b": 90], now: t0) == ["a", "b"], "standing: the first order is by score")
        check(s.rank(["a": 100, "b": 120], now: t0.addingTimeInterval(30)) == ["a", "b"], "reshuffle: beating the one above by less than 25% moves nothing")
        check(s.rank(["a": 100, "b": 130], now: t0.addingTimeInterval(60)) == ["a", "b"], "reshuffle: beating it by 25% must hold first")
        check(s.rank(["a": 100, "b": 130], now: t0.addingTimeInterval(200)) == ["a", "b"], "reshuffle: not yet after 2 min 20 s")
        check(s.rank(["a": 100, "b": 130], now: t0.addingTimeInterval(241)) == ["b", "a"], "reshuffle: held for 3 min, it moves up")
        check(s.rank(["a": 140, "b": 130], now: t0.addingTimeInterval(250)) == ["b", "a"], "reshuffle: a brief lead back moves nothing")
        check(s.rank(["a": 100, "b": 130, "c": 500], now: t0.addingTimeInterval(260)) == ["b", "a", "c"], "standing: a new thread starts below")
        check(s.rank(["a": 100, "c": 500], now: t0.addingTimeInterval(270)) == ["a", "c"], "standing: a forgotten thread leaves at once")
        // A brief spike that drops back resets its timer.
        var r = DayReviewStanding()
        _ = r.rank(["a": 100, "b": 50], now: t0)
        _ = r.rank(["a": 100, "b": 200], now: t0.addingTimeInterval(10))
        _ = r.rank(["a": 100, "b": 60], now: t0.addingTimeInterval(100))
        check(r.rank(["a": 100, "b": 200], now: t0.addingTimeInterval(200)) == ["a", "b"], "reshuffle: a spike that dropped back starts its hold over")
        // DayReviewMemory: today's card keeps its order; a new day starts empty; a past day is by score.
        let memory = DayReviewMemory()
        let one = thread("one", "project", 100, [item("o", "Worked on One")]), two = thread("two", "project", 90, [item("t", "Worked on Two")])
        _ = memory.groups(DayReviewFacts(day: "2026-10-03", threads: [one, two], clauses: [:], activeSeconds: 0, personSends: 0), live: true, now: t0)
        var two2 = two; two2.score = 200
        let held = memory.groups(DayReviewFacts(day: "2026-10-03", threads: [one, two2], clauses: [:], activeSeconds: 0, personSends: 0), live: true, now: t0.addingTimeInterval(30))
        check(held.first?.bullets.first?.thread == "one", "card memory: today's order holds through a reshuffle attempt")
        let midnight = memory.groups(DayReviewFacts(day: "2026-10-04", threads: [one, two2], clauses: [:], activeSeconds: 0, personSends: 0), live: true, now: t0.addingTimeInterval(60))
        check(midnight.first?.bullets.first?.thread == "two", "card memory: a new day starts from its own scores")
        let past = memory.groups(DayReviewFacts(day: "2026-10-02", threads: [one, two2], clauses: [:], activeSeconds: 0, personSends: 0), live: false)
        check(past.first?.bullets.first?.thread == "two", "day navigation: a past day shows its final order at once")
    }

    // MARK: clauses

    static func clauses() {
        check(DayReviewClauses.instruction.utf8.count <= 8192, "clause instruction is at most 8192 bytes (\(DayReviewClauses.instruction.utf8.count))")
        let r = DayReviewClauseRequest(day: "2026-10-03", timezone: zone, key: "person:jamie lin", lead: "Told Jamie Lin", name: "Jamie Lin", colon: false,
                                       notes: ["Texted Jamie Lin: plans for ZUX tomorrow with friends."], signature: "s3|p0|m2", actionIDs: ["a"], start: "", end: "")
        check((try? DayReviewClauses.validate("you and friends are going to ZUX tomorrow\"}", request: r)) == "you and friends are going to ZUX tomorrow",
              "clause: a good continuation passes (prefill style)")
        check((try? DayReviewClauses.validate("{\"clause\":\"You and friends are going to ZUX tomorrow.\"}", request: r)) == "you and friends are going to ZUX tomorrow",
              "clause: a sentence that goes on starts lower case, without its period")
        let w = DayReviewClauseRequest(day: "2026-10-03", timezone: zone, key: "code:daydream", lead: "Worked on DayDream", name: "DayDream", colon: true,
                                       notes: ["Fixed Messages sends saved as drafts in DayDream; the Ghostty spinner."], signature: "s0|p0|m3", actionIDs: ["a"], start: "", end: "")
        check((try? DayReviewClauses.validate("{\"clause\":\"Messages sends saved as drafts and the Ghostty spinner\"}", request: w)) == "Messages sends saved as drafts and the Ghostty spinner",
              "clause: a description after a colon keeps its capital")
        let bad: [(String, String)] = [
            ("{\"clause\":\"\\\"hahaha\\\" said the plans\"}", "quotes"), ("{\"clause\":\"plans for about 30 minutes\"}", "duration"),
            ("{\"clause\":\"the user made plans at 9:30\"}", "time and subject"), ("{\"clause\":\"made plans with Jordan Lee\"}", "unknown name"),
            ("{\"clause\":\"told Jamie about plans\"}", "repeats the lead"), ("{\"clause\":\"sent the plans to friends\"}", "unsupported sent"),
            ("{\"clause\":\"plans with key sk-live-4f9a8b7c6d5e4f3a2b1c\"}", "secret"), ("{\"answer\":1}", "shape"),
            ("{\"clause\":\"one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen seventeen\"}", "too long")]
        for (raw, why) in bad { check((try? DayReviewClauses.validate(raw, request: r)) == nil, "clause: refused (\(why))") }
        check(DayReviewClauses.evidence(r).count <= DayReviewClauses.evidenceChars + 200, "clause evidence is bounded")
    }

    // MARK: store fixtures

    static func stores() async throws {
        let now = date(3, 13, 0)
        let today = key(now)

        // Work-heavy day.
        let work = try Fixture("work")
        try seedWork(work, day: 3)
        try work.window(slack.0, slack.1, "#launch - Fixture", at: date(3, 12, 10), minutes: 6)
        try work.notes(now)
        guard let facts = try work.review(now) else { check(false, "work day: review facts"); return }
        let groups = DayReview.assemble(facts)
        let lines = shapes(groups)
        print("work day threads: " + facts.threads.map { "\($0.key)=\($0.score)" }.joined(separator: ", "))
        print("work day bullets: \(lines)")
        check(facts.threads.first?.key == "project:daydream" && facts.threads.first?.name == "DayDream",
              "work day: Ghostty, Terminal and GitHub about DayDream are one thread, on top (\(facts.threads.first?.key ?? "-"))")
        check(groups.first?.bullets.allSatisfy { $0.thread == "project:daydream" } == true && (groups.first?.bullets.count ?? 0) >= 2,
              "work day: the top group is the project's (\(groups.first?.bullets.count ?? 0) bullets)")
        check(lines.first?.contains("DayDream") == true, "work day: the bullet names the project")
        check(lines.count <= 7 && !lines.contains { $0.contains("~") || $0.range(of: #"\b\d+ (min|hr)\b"#, options: .regularExpression) != nil },
              "work day: 7 bullets at most, no durations")
        let watched = groups.flatMap(\.bullets).first { $0.lead == "Watched" }
        check(watched?.link?.title == "\u{201C}How do lighthouse lenses work?\u{201D}" && watched?.link?.url?.hasPrefix("https://www.youtube.com") == true
              && watched?.rest == "on YouTube", "work day: Watched “title” on YouTube, linked (\(watched.map(shape) ?? "-") \(watched?.link?.url ?? "-"))")
        check(facts.warm && facts.clauses.isEmpty, "work day: warm, no clause yet")

        // The clause writer (fake model): one clause per shown thread, then nothing until a material change.
        let answers = Answers(["{\"clause\":\"the Messages drafts fix and its pull request\"}"])
        let binding = LevelWriterBinding(store: work.store, generate: { _, _, _, _ in try await answers.next() })
        let step = try await binding.reviewClause(timezone: zone, now: now)
        check(step?.clause.key != nil && step?.source == "model", "clauses: the model's clause is checked and saved (\(step?.clause.key ?? "-"))")
        var after = try work.review(now)
        check(after.map { !$0.clauses.isEmpty } == true, "clauses: the day read carries the cached clause")
        let withClause = after.map { shapes(DayReview.assemble($0)) } ?? []
        check(withClause.contains { $0.contains("the Messages drafts fix and its pull request") }, "clauses: the bullet uses it (\(withClause.first ?? "-"))")
        let due = try work.store.reviewClauseWork(timezone: zone, now: now.addingTimeInterval(60))
        check(!due.contains { $0.key == step?.clause.key }, "clauses: not written again without a material change")
        // A refused answer, then a good one: the repair turn.
        let repairAnswers = Answers(["{\"clause\":\"\\\"quoted\\\" words\"}", "{\"clause\":\"the drafts fix in Messages\"}"])
        let repairing = LevelWriterBinding(store: work.store, generate: { _, _, _, _ in try await repairAnswers.next() })
        if let next = try await repairing.reviewClause(timezone: zone, now: now) {
            check(next.source == "repair" && next.rejections.count == 1, "clauses: a refused answer gets one repair turn")
        } else { check(due.isEmpty, "clauses: nothing else due (\(due.count))") }

        // Model failure: no clause, no error in the review, the code's bullets stay; the runner backs off.
        let failing = try Fixture("failure")
        try seedWork(failing, day: 3)
        try failing.notes(now)
        let broken = LevelWriterBinding(store: failing.store, generate: { _, _, _, _ in throw NSError(domain: "fixture-model", code: 1) })
        let runner = LevelRunner()
        var threw = false
        do { _ = try await runner.clause(broken, timezone: zone, now: now) } catch is LevelWriterBinding.ModelFailure { threw = true }
        let second = try? await runner.clause(broken, timezone: zone, now: now.addingTimeInterval(5))
        let failedFacts = try failing.review(now)
        check(threw && second == nil && failedFacts.map { $0.clauses.isEmpty && !DayReview.assemble($0).isEmpty } == true,
              "model failure: nothing saved, the runner waits, the review keeps its code bullets")
        check(try failing.store.reviewClauses(day: today).isEmpty, "model failure: no clause row")

        // Forget: the watched video's bullet and a thread's clause go with their records, at once.
        let clauseKey = step?.clause.key ?? ""
        try work.forget(date(3, 11, 40), date(3, 11, 55), now: now)
        after = try work.review(now)
        let afterLines = after.map { shapes(DayReview.assemble($0)) } ?? []
        check(!afterLines.contains { $0.hasPrefix("Watched") }, "forget: the forgotten video's bullet is gone (\(afterLines))")
        try work.forget(date(3, 9, 0), date(3, 11, 35), now: now)
        let clausesLeft = try work.store.reviewClauses(day: today)
        after = try work.review(now)
        check(clausesLeft[clauseKey] == nil && after.map { !$0.threads.contains { $0.key == "project:daydream" } } ?? true,
              "forget: the project's bullets and its clause are gone")

        // Excluded app: Slack rows recorded before Slack was excluded never show.
        let excluded = try Fixture("excluded")
        try seedWork(excluded, day: 3)
        try excluded.window(slack.0, slack.1, "Maya (DM) - Fixture", at: date(3, 12, 10), minutes: 30)
        let before = try excluded.review(now)
        var policy = try excluded.store.policy(); policy.blockedApps.append(slack.1); try excluded.store.updatePolicy(policy, now: now)
        let without = try excluded.review(now)
        let slackShown = { (f: DayReviewFacts?) in f.map { shapes(DayReview.assemble($0)).contains { $0.contains("Maya") || $0.contains("Slack") } } ?? false }
        check(slackShown(before) && !slackShown(without), "excluded app: never in the review (shown before: \(slackShown(before)))")

        // Early-morning thin day: code bullets only, no clause work until 20 minutes or a few sends.
        let thin = try Fixture("thin")
        try thin.window(ghostty.0, ghostty.1, "~/daydream", at: date(3, 6, 0), minutes: 6)
        try thin.window(chrome.0, chrome.1, "Hacker News", url: "https://news.ycombinator.com", at: date(3, 6, 7), minutes: 3)
        try thin.notes(date(3, 6, 15))
        let early = try thin.review(date(3, 6, 15))
        check(early.map { !$0.warm && !DayReview.assemble($0).isEmpty } == true, "thin day: code bullets, not warm (\(early.map { shapes(DayReview.assemble($0)) } ?? []))")
        check(try thin.store.reviewClauseWork(timezone: zone, now: date(3, 6, 15)).isEmpty, "thin day: no model work")

        // A day with only reading and watching still gets bullets; midnight starts empty.
        let reading = try Fixture("reading")
        try reading.window(chrome.0, chrome.1, "How do lighthouse lenses work? - YouTube", url: "https://www.youtube.com",
                           page: "https://www.youtube.com/watch?v=fixture01", at: date(3, 20, 0), minutes: 25)
        try reading.window(chrome.0, chrome.1, "The fixture essay - Example Blog", url: "https://blog.example.com", page: "https://blog.example.com/essay",
                           at: date(3, 20, 30), minutes: 15)
        let reads = try reading.review(date(3, 21, 0)).map { shapes(DayReview.assemble($0)) } ?? []
        check(reads.contains { $0.hasPrefix("Watched") } && reads.count >= 2, "reading day: bullets (\(reads))")
        check(try reading.review(date(4, 0, 5)) == nil, "midnight: the new day starts empty")

        try await asks(now: now)
        try await mixed(now: now)
        try await people(now: now)
    }

    /// claude/today-rank-1005 (owner 10/05): a mixed day with heavy texting and Claude, Google Docs and terminal work. The
    /// work leads, browsing comes next, and the texting shows once, last. Both lanes: the public check build keeps no typed
    /// row, so there the texting is an hour of Messages windows; the owner lane adds the texts and an ask.
    static func mixed(now: Date) async throws {
        let claude = ("Claude", "com.anthropic.claudefordesktop")
        let f = try Fixture("mixed")
        for (i, h) in [8, 9, 10, 11, 12].enumerated() {
            try f.window(messages.0, messages.1, "Jamie Lin", at: date(3, h, 0), minutes: 14)
            #if DAYDREAM_OWNER_TYPING
            for k in 0..<3 {
                try f.typed(messages.0, messages.1, "Jamie Lin", at: date(3, h, 2 + k * 4), words: "fixture text \(i).\(k) about the weekend plans and the long drive",
                            surface: "text", to: "Jamie Lin", edits: 12, composeSeconds: 150)
            }
            #endif
        }
        try f.window(claude.0, claude.1, "Claude", at: date(3, 8, 20), minutes: 25)
        #if DAYDREAM_OWNER_TYPING
        try f.typed(claude.0, claude.1, "Claude", at: date(3, 8, 30), words: "fixture question about the launch checklist", surface: "ai")
        #endif
        try f.window(chrome.0, chrome.1, "Launch plan - Google Docs", url: "https://docs.google.com", page: "https://docs.google.com/document/d/fixture/edit",
                     at: date(3, 9, 20), minutes: 30)
        try f.window(ghostty.0, ghostty.1, "~/tallybird", at: date(3, 10, 20), minutes: 35)
        try f.window(chrome.0, chrome.1, "Ada on X: \"New models soon\" / X", url: "https://x.com", page: "https://x.com/fixture/status/1", at: date(3, 11, 20), minutes: 12)
        try f.notes(now)
        guard let facts = try f.review(now) else { check(false, "mixed day: review facts"); return }
        let byKey = Dictionary(facts.threads.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        print("mixed day threads: " + facts.threads.map { "\($0.key)=\($0.score) \($0.rankCategory.rawValue)" }.joined(separator: ", "))
        let jamie = facts.threads.first { $0.rankCategory == .personal }
        check(jamie != nil && facts.threads.first?.rankCategory == .personal,
              "mixed day: by importance alone the texting is on top (\(facts.threads.first.map { $0.key + "=\($0.score)" } ?? "-"))")
        let bullets = DayReview.assemble(facts).flatMap(\.bullets)
        let categories = bullets.map { $0.thread == "texting" ? .personal : byKey[$0.thread]?.rankCategory ?? .browsing }
        print("mixed day bullets: \(bullets.map(shape)) \(categories.map(\.rawValue))")
        let work = bullets.filter { byKey[$0.thread]?.rankCategory == .work }.map(\.thread)
        // Without typing, a Claude window with no ask is filler and drops out; the doc and the terminal still lead.
        #if DAYDREAM_OWNER_TYPING
        let workLines = 3
        #else
        let workLines = 2
        #endif
        check(Set(work).count >= workLines && categories.prefix(while: { $0 == .work }).count == work.count,
              "mixed day: Claude, Google Docs and the terminal lead (\(Set(work).sorted()))")
        check(categories.filter { $0 == .personal }.count == 1 && categories.last == .personal, "mixed day: the texting shows once, last")
        check(!bullets.contains { $0.text.hasPrefix("Worked on Claude") }, "mixed day: Claude read with no ask is \"Used Claude\", never \"Worked on Claude: in Claude\"")
        check(categories.firstIndex(of: .browsing).map { $0 > (categories.lastIndex(of: .work) ?? -1) } ?? true, "mixed day: browsing after the work")
        check(DayReview.assemble(facts).count <= DayReview.slots.count && bullets.count <= DayReview.lineBudget, "mixed day: six lines at most (\(bullets.count) bullets)")
        #if DAYDREAM_OWNER_TYPING
        let textingLine = "Texted Jamie Lin."
        #else
        let textingLine = "Read texts from Jamie Lin."
        #endif
        check(bullets.last.map { $0.thread == "texting" && $0.text == textingLine && $0.quote == nil } == true,
              "mixed day: the texting line names Jamie, no quote (\(bullets.last.map(shape) ?? "-"))")
        // The card's live order (hysteresis) agrees.
        let live = DayReviewMemory().groups(facts, live: true, now: now).flatMap(\.bullets).map { $0.thread == "texting" ? .personal : byKey[$0.thread]?.rankCategory ?? .browsing }
        check(live.first == .work && live.filter { $0 == .personal }.count == 1 && live.last == .personal, "mixed day: the live card the same")
        // The clause writer writes for what shows: never for the texting's second line.
        let due = try f.store.reviewClauseWork(timezone: zone, now: now, limit: 20)
        check(due.allSatisfy { r in bullets.contains { $0.thread == r.key || $0.id == r.key || $0.id.hasPrefix(r.key + "#") } },
              "mixed day: clauses only for shown lines (\(due.map(\.key)))")
    }

    /// claude/today-copy-1004 (owner 10/04): asks typed in the Claude and ChatGPT apps' own threads read "Asked Claude: “…”"
    /// and "Asked ChatGPT: “…”", never "Asked Claude about Claude";
    /// an ask in a project keeps its "about DayDream".
    static func asks(now: Date) async throws {
        let claude = ("Claude", "com.anthropic.claudefordesktop"), chatgpt = ("ChatGPT", "com.openai.chat")
        let f = try Fixture("asks")
        try seedWork(f, day: 3, from: 7)
        let p = try f.typed(ghostty.0, ghostty.1, "~/daydream", at: date(3, 8, 30), words: "fixture ask about the export button", surface: "aiTool")
        try f.window(claude.0, claude.1, "Claude", at: date(3, 10, 0), minutes: 12)
        let c = try f.typed(claude.0, claude.1, "Claude", at: date(3, 10, 6), words: "fixture question about running the build over ssh", surface: "ai")
        try f.window(chatgpt.0, chatgpt.1, "ChatGPT", at: date(3, 11, 0), minutes: 12)
        let g = try f.typed(chatgpt.0, chatgpt.1, "ChatGPT", at: date(3, 11, 6), words: "fixture question about the chart colors", surface: "ai")
        #if !DAYDREAM_OWNER_TYPING
        // This check build saves no synthetic typed row (as the texting fixtures): the asks fixture runs in the owner lane;
        // the pure "about" and no-bold checks above, and ui-copy's T1, run in both.
        check(p == nil && c == nil && g == nil, "public check build: no typed row saved here (the asks fixture runs in the owner lane)")
        return
        #else
        try f.notes(now)
        guard c != nil, g != nil, let facts = try f.review(now) else {
            check(false, "asks: the fixture's asks are saved and reviewed (claude \(c != nil), chatgpt \(g != nil))"); return
        }
        let items = facts.threads.flatMap(\.items).filter { $0.lead.hasPrefix("Asked ") }
        print("asks day items: " + items.map { $0.lead + " | " + ($0.tail ?? "-") }.joined(separator: ", "))
        let want = ["Asked Claude", "Asked ChatGPT"]
        let apps = items.filter { want.contains($0.lead) }
        check(Set(apps.map(\.lead)) == Set(want), "asks: one ask line per AI app (\(items.map(\.lead)))")
        check(apps.allSatisfy { $0.tail == nil }, "asks: no \"about …\" that only names the app again (\(apps.compactMap(\.tail)))")
        let project = facts.threads.first { $0.key == "project:daydream" }?.items.first { $0.lead.hasPrefix("Asked ") }
        check(p != nil && project?.tail == "about DayDream", "asks: an ask in a project keeps \"about DayDream\" (\(project.map { $0.lead + " " + ($0.tail ?? "-") } ?? "-"))")
        let words = try f.store.ownerReviewQuotes(facts.quoteIDs, now: now)
        let lines = DayReview.assemble(facts, quotes: words).flatMap(\.bullets)
        let shaped = lines.map(shape)
        check(want.allSatisfy { shaped.contains($0 + ": \u{201C}«q»\u{201D}") }, "asks: \(want.map { "\"" + $0 + ": “…”\"" }.joined(separator: " and ")) (\(shaped))")
        check(!lines.contains { b in ["about claude", "about chatgpt", "about codex"].contains { b.fullText.lowercased().contains($0) } },
              "asks: never \"about Claude\", \"about ChatGPT\" or \"about Codex\"")
        // Without the words (every MCP and CLI process), the line is "Asked Claude.", still with no about.
        let bare = DayReview.assemble(facts, quotes: [:]).flatMap(\.bullets).map(\.text)
        check(want.allSatisfy { bare.contains($0 + ".") }, "asks: with no words opened, \"\(want[0]).\" (\(bare))")
        try await typedFacts(f, now: now)
        #endif
    }

    /// claude/dayeval-1005 (owner: typed words are read by the summarizer on this Mac only): the clause writer on this Mac
    /// reads the thread's typed prompts ("asked: …"); a cloud writer never does; a request, the review's facts and its
    /// cache hold ids only; a clause that copies five typed words in a row is refused.
    /// claude/dayeval-1005 (owner 10/04): plain words on the card; no bare "Used Claude."; never draft or unsent.
    static func plainWords() {
        equal(DayReview.titleAsObject("How tide pools form"), "\u{201C}How tide pools form\u{201D}", "plain words: a title that reads as words of the sentence is quoted")
        equal(DayReview.titleAsObject("Lab Report"), "Lab Report", "plain words: any other title stays as it is")
        equal(DayReview.lowerLead("Testing Tallybird sync"), "testing Tallybird sync", "plain words: \"about testing …\", never \"about Testing …\"")
        equal(DayReview.lowerLead("Market sizing for the bakery"), "market sizing for the bakery", "plain words: an ordinary first word in lower case")
        equal(DayReview.lowerLead("Tallybird login issues"), "Tallybird login issues", "plain words: a name keeps its capitals")
        equal(DayReview.lowerLead("Tallybird export crash"), "Tallybird export crash", "plain words: an unknown capitalized word is taken for a name")
        equal(MemoryStore.plainSite("en.wikipedia.org"), "Wikipedia", "plain words: a site by its name (Wikipedia)")
        equal(MemoryStore.plainSite("courses.northlake.edu", titles: ["Courses at NorthLake"]), "NorthLake", "plain words: spelled as its pages spell it")
        equal(MemoryStore.plainSite("canvas.northlake.edu"), "Canvas", "plain words: a school's tool by the tool's name")
        check(MemoryStore.chromePage("Lesson Viewer") && MemoryStore.chromePage("Student Portal") && !MemoryStore.chromePage("Problem Set 5"),
              "plain words: pages that only name the app are no topic")
        // A card with nothing but filler never shows a bare "Used Claude." (an AI app opened with nothing asked).
        let claude = DayReviewThread(key: "ai:claude", name: "Claude", kind: "ai", seconds: 900, words: 0, personSends: 0, asks: 0, sendHours: 0, stakes: [],
                                     score: 15, items: [DayReviewItem(id: "ai:claude", lead: "Used Claude", clauseKey: "ai:claude", score: 15, moments: ["m"], filler: true)],
                                     moments: ["m"], category: "work")
        let notes = DayReviewThread(key: "app:notes", name: "Notes", kind: "app", seconds: 600, words: 0, personSends: 0, asks: 0, sendHours: 0, stakes: [],
                                    score: 10, items: [DayReviewItem(id: "app:notes", lead: "Used", tail: "Notes", score: 10, moments: ["n"], filler: true)],
                                    moments: ["n"], category: "browsing")
        let thin = DayReviewFacts(day: "2026-10-05", threads: [claude, notes], clauses: [:], activeSeconds: 1500, personSends: 0)
        let shown = DayReview.assemble(thin, quotes: [:]).flatMap(\.bullets).map(\.text)
        check(!shown.contains("Used Claude.") && shown.contains("Used Notes."), "plain words: no bare \"Used Claude.\" even on a card of filler (\(shown))")
        // The main app by time, an AI app with nothing asked, says when (never "Used ChatGPT."); only that app, from 15 minutes.
        func ai(_ seconds: Int, part: String?) -> DayReviewThread {
            DayReviewThread(key: "ai:chatgpt", name: "ChatGPT", kind: "ai", seconds: seconds, words: 0, personSends: 0, asks: 0, sendHours: 0, stakes: [],
                            score: Double(seconds) / 60, items: [DayReviewItem(id: "ai:chatgpt", lead: "Used ChatGPT", clauseKey: "ai:chatgpt", score: 1, moments: ["g"], filler: true)],
                            moments: ["g"], category: "work", dayPart: part)
        }
        let quiet = DayReviewThread(key: "app:notes", name: "Notes", kind: "app", seconds: 300, words: 0, personSends: 0, asks: 0, sendHours: 0, stakes: [],
                                    score: 5, items: [DayReviewItem(id: "app:notes", lead: "Used", tail: "Notes", score: 5, moments: ["n"], filler: true)], moments: ["n"], category: "browsing")
        func card(_ threads: [DayReviewThread]) -> [String] {
            DayReview.assemble(DayReviewFacts(day: "2026-10-05", threads: threads, clauses: [:], activeSeconds: 3000, personSends: 0), quotes: [:]).flatMap(\.bullets).map(\.text)
        }
        let thinDay = card([ai(1700, part: "afternoon"), quiet])
        check(thinDay.contains("Spent time in ChatGPT in the afternoon.") && !thinDay.contains("Used ChatGPT."), "time line: the main app with nothing asked says when (\(thinDay))")
        let longDay = card([ai(6000, part: "afternoon"), quiet])
        check(longDay.contains("Spent the afternoon in ChatGPT."), "time line: an afternoon's worth reads \"Spent the afternoon\" (\(longDay))")
        let notMain = card([ai(1700, part: "afternoon"), DayReviewThread(key: "app:notes", name: "Notes", kind: "app", seconds: 2400, words: 0, personSends: 0, asks: 0,
                                                                          sendHours: 0, stakes: [], score: 5, items: quiet.items, moments: ["n"], category: "browsing")])
        check(!notMain.contains { $0.hasPrefix("Spent") }, "time line: only for the day's main app (\(notMain))")
        let short = card([ai(600, part: "morning"), quiet])
        check(!short.contains { $0.hasPrefix("Spent") }, "time line: not under 15 minutes (\(short))")
        equal(MemoryStore.dayPart([("2026-10-05T13:00:00Z", "2026-10-05T15:00:00Z")], timezone: "UTC"), String?.some("afternoon"), "time line: two afternoon hours are the afternoon")
        equal(MemoryStore.dayPart([("2026-10-05T09:00:00Z", "2026-10-05T10:00:00Z"), ("2026-10-05T14:00:00Z", "2026-10-05T15:00:00Z")], timezone: "UTC"), String?.none,
              "time line: split across the day, no part")
        // Read-only texting names the conversations read for a while; one only passed on the way is "others".
        func person(_ name: String, seconds: Int, sends: Int = 0) -> DayReviewThread {
            DayReviewThread(key: "person:" + name.lowercased(), name: name, kind: "person", seconds: seconds, words: 0, personSends: sends, asks: 0, sendHours: 0,
                            stakes: [], score: Double(seconds) / 60, items: [], moments: [name], category: "personal")
        }
        let read = DayReview.textingBullet([person("Ana Ruiz", seconds: 240), person("Cy Tran", seconds: 4)], words: [:], options: DayReview.options)
        equal(read?.text, "Read texts from Ana Ruiz and others.", "texting: a conversation only glanced at is not named")
        let glanced = DayReview.textingBullet([person("Cy Tran", seconds: 4)], words: [:], options: DayReview.options)
        equal(glanced?.text, "Read texts.", "texting: nothing read for long names no one")
        let texted = DayReview.textingBullet([person("Cy Tran", seconds: 4, sends: 1)], words: [:], options: DayReview.options)
        equal(texted?.text, "Texted Cy Tran.", "texting: a quick text still names who it went to")
        // Never draft or unsent in a clause (the owner: most "drafts" were sent), unless a title says draft.
        let r = DayReviewClauseRequest(day: "2026-10-05", timezone: zone, key: "doc:x", lead: "Worked on Launch plan", name: "Launch plan", colon: true,
                                       notes: ["titles: Launch plan; Pricing page", "apps: Pages", "typed or sent: typed about 80 words"], signature: "s", actionIDs: ["a"],
                                       start: "2026-10-05T10:00:00Z", end: "2026-10-05T11:00:00Z")
        for bad in ["an unsent pricing page note", "a draft of the pricing page", "the pricing page, not sent"] {
            var refused = false
            do { _ = try DayReviewClauses.validatePacket("{\"clause\":\"\(bad)\"}", request: r) } catch is DayReviewClauses.Reject { refused = true } catch {}
            check(refused, "never draft or unsent: \"\(bad)\" is refused")
        }
        check(!DayReviewClauses.packetInstruction.isEmpty && DayReviewClauses.packetInstruction.contains("Never say draft, unsent or not sent."),
              "never draft or unsent: the writer is told so")
    }

    static func typedFacts(_ f: Fixture, now: Date) async throws {
        let prompt = "fixture question about running the build over ssh"
        let due = try f.store.reviewClauseWork(timezone: zone, now: now, limit: 20)
        let claudeAsk = due.first { $0.lead == "Asked Claude" }
        check(claudeAsk?.typedIDs?.isEmpty == false, "typed facts: the Claude ask's clause request names its typed row (\(due.map(\.key)))")
        check(!due.contains { r in r.notes.contains { $0.contains(prompt) } }, "typed facts: a clause request never carries typed words itself")
        if let facts = try f.review(now), let data = try? JSONEncoder().encode(facts) {
            check(!String(decoding: data, as: UTF8.self).contains(prompt), "typed facts: the review's facts never hold typed words")
        }
        guard let claudeAsk else { return }
        let seen = Evidences()
        let local = LevelWriterBinding(store: f.store, generate: { _, e, _, _ in
            await seen.add(e); return e.contains("asked: " + prompt) ? "{\"clause\":\"about running builds remotely\"}" : "{\"clause\":\"\"}" })
        var localStep: LevelWriterBinding.ClauseStep?
        for _ in 0..<8 {
            guard let step = try await local.reviewClause(timezone: zone, now: now) else { break }
            if step.clause.key == claudeAsk.key { localStep = step }
        }
        let localEvidence = await seen.all
        check(localEvidence.contains { $0.contains("asked: " + prompt) }, "typed facts: the writer on this Mac reads the prompt")
        check(localStep != nil, "typed facts: a clause written from the prompt in other words is saved (\(localStep?.clause.text ?? "-"))")
        let cloudSeen = Evidences()
        let cloud = LevelWriterBinding.cloud(store: f.store, model: "fixture-cloud", permits: { _ in true },
                                             complete: { _, e, _ in await cloudSeen.add(e); return "{\"clause\":\"\"}" })
        _ = try? await cloud.reviewClause(timezone: zone, now: now.addingTimeInterval(3600))
        let cloudEvidence = await cloudSeen.all
        check(!cloudEvidence.contains { $0.contains("asked:") || $0.contains("fixture question") }, "typed facts: a cloud writer never reads typed words (\(cloudEvidence.count) asks)")
        let typedLines = try f.store.reviewTypedFacts(claudeAsk, writer: .cloud, now: now)
        check(typedLines.isEmpty, "typed facts: none for a cloud writer, whoever asks")
        // A clause that copies the prompt is refused; one that says it in other words passes.
        var r = claudeAsk; r.notes = ["titles: Claude", "apps: Claude", "typed or sent: asked an AI app 1 times", "asked: " + prompt]
        var refused = false
        do { _ = try DayReviewClauses.validatePacket("{\"clause\":\"about running the build over ssh\"}", request: r) } catch is DayReviewClauses.Reject { refused = true }
        check(refused, "typed facts: a clause that copies five typed words in a row is refused")
        check((try? DayReviewClauses.validatePacket("{\"clause\":\"about running builds remotely\"}", request: r)) == "about running builds remotely",
              "typed facts: the same topic in other words passes")
        check((try? DayReviewClauses.validatePacket("{\"clause\":\"running builds remotely\"}", request: r)) == "about running builds remotely",
              "typed facts: an ask's clause that leaves out \"about\" gets it from code")
        var doc = r; doc.lead = "Wrote"; doc.name = "Garden"; doc.notes = ["titles: Garden", "apps: Notes", "typed or sent: typed about 20 words", "wrote: plant the tomatoes after the last frost and water them daily"]
        check((try? DayReviewClauses.validatePacket("{\"clause\":\"planting tomatoes after frost\"}", request: doc)) == "about planting tomatoes after frost",
              "typed facts: \"Wrote planting …\" is \"Wrote about planting …\" (an ending changed is still the person's word)")
    }

    /// The texting fixtures (owner build: Messages typing).
    static func people(now: Date) async throws {
        let probe = try Fixture("probe")
        let accepted = try probe.typed(messages.0, messages.1, "Jamie Lin", at: date(3, 9, 0), words: "fixture text", surface: "text", to: "Jamie Lin") != nil
        #if DAYDREAM_OWNER_TYPING
        check(accepted, "owner build: a Messages typed row is saved")
        #else
        check(!accepted, "public build: no Messages typed row is ever saved (texting fixtures run in the owner lane)")
        return
        #endif

        // Texting-heavy day: Jamie across four separate hours beats a little work. claude/today-rank-1005: the work is a few
        // minutes (little else), so the card is in score order and the texting line leads; `mixed` has a day with real work.
        // claude/dayeval-1005 (owner 10/05): one texting line, names only; a quote is an owner choice (`textingQuote`).
        let texting = try Fixture("texting")
        try texting.window(ghostty.0, ghostty.1, "~/daydream", at: date(3, 8, 0), minutes: 6)
        var quoteIDs = [String]()
        for (i, h) in [9, 10, 11, 12, 12].enumerated() {
            try texting.window(messages.0, messages.1, "Jamie Lin", at: date(3, h, 5 + i), minutes: 2)
            if let id = try texting.typed(messages.0, messages.1, "Jamie Lin", at: date(3, h, 6 + i), words: "fixture plan number \(i) for tomorrow with friends",
                                          surface: "text", to: "Jamie Lin", edits: i == 2 ? 30 : 0, composeSeconds: i == 2 ? 200 : 15) { quoteIDs.append(id) }
        }
        let tFacts = try texting.review(now)
        print("texting day threads: " + (tFacts?.threads.map { "\($0.key)=\($0.score) sends=\($0.personSends) hours=\($0.sendHours)" }.joined(separator: ", ") ?? "-"))
        check(tFacts?.threads.first?.key == "person:jamie lin" && tFacts?.threads.first?.sendHours ?? 0 >= 3,
              "texting day: one thread for Jamie across Messages, on top")
        let words = try texting.store.ownerReviewQuotes(tFacts?.quoteIDs ?? [], now: now)
        let tGroups = tFacts.map { DayReview.assemble($0, quotes: words) } ?? []
        let top = tGroups.first?.bullets ?? []
        check(top.count == 1 && top.first?.thread == "texting", "texting day: the texting line leads, one line (\(top.map(shape)))")
        check(top.first?.text == "Texted Jamie Lin." && top.first?.quote == nil, "texting day: names only, no quote (\(top.first.map(shape) ?? "-"))")
        let quotedTop = tFacts.map { DayReview.assemble($0, quotes: words, options: DayReview.options.union(.textingQuote)) }?.first?.bullets ?? []
        check(quotedTop.count == 1 && quotedTop.first?.quote != nil, "texting day: with the owner's quote choice, the line keeps one quote (\(quotedTop.map(shape)))")
        check(quotedTop.compactMap(\.quote).allSatisfy { q in quoteIDs.contains { (words[$0] ?? "") == q } }, "texting day: quotes are the texts' exact words")

        // High-stakes single text: a long, late, first text to a new contact earns its own bullet on a work-heavy day.
        let stakes = try Fixture("stakes")
        try seedWork(stakes, day: 3, from: 9)
        try stakes.window(ghostty.0, ghostty.1, "~/daydream", at: date(3, 13, 0), minutes: 60)
        try stakes.window(messages.0, messages.1, "Jordan Lee", at: date(3, 23, 20), minutes: 6)
        let long = Array(repeating: "fixture", count: 50).joined(separator: " ")
        let jid = try stakes.typed(messages.0, messages.1, "Jordan Lee", at: date(3, 23, 25), words: long, surface: "text", to: "Jordan Lee", edits: 40, composeSeconds: 300)
        let sFacts = try stakes.review(date(3, 23, 40))
        let jordan = sFacts?.threads.first { $0.key == "person:jordan lee" }
        print("stakes day threads: " + (sFacts?.threads.map { "\($0.key)=\($0.score)" }.joined(separator: ", ") ?? "-"))
        check(jid != nil && Set(jordan?.stakes ?? []).isSuperset(of: [.long, .firstContact, .lateNight]), "high stakes: long, first contact, late night (\(jordan?.stakes ?? []))")
        check(sFacts?.threads.first?.key == "project:daydream", "high stakes: the work project still leads")
        let shown = sFacts.map { DayReview.assemble($0).flatMap(\.bullets) } ?? []
        check(shown.contains { $0.thread == "texting" && $0.text.contains("Jordan Lee") && $0.quote == nil },
              "high stakes: the texting line names who it was to, no quote (\(shown.map(shape)))")

        // Never a secret: a text the scrubber would hold back is never quoted.
        let secret = try Fixture("secret")
        try secret.window(messages.0, messages.1, "Sam Park", at: date(3, 10, 0), minutes: 3)
        let sid = try secret.typed(messages.0, messages.1, "Sam Park", at: date(3, 10, 1), words: "the door code is 4829 and key sk-live-4f9a8b7c6d5e4f3a2b1c", surface: "text", to: "Sam Park")
        let secretWords = try secret.store.ownerReviewQuotes([sid ?? "-"], now: now)
        check(sid != nil && secretWords.isEmpty, "quotes: a text with a code or key is never quoted")
        // Forget "what I typed": typed clauses go with it (commit one first).
        _ = try? texting.store.commitReviewClause(DayReviewClauseRequest(day: key(now), timezone: zone, key: "person:jamie lin", lead: "Told Jamie Lin", name: "Jamie Lin",
                                                                          colon: false, notes: ["n"], signature: "s5|p0|m0", actionIDs: quoteIDs, start: "", end: ""),
                                                  text: "plans for tomorrow with friends", now: now)
        check(try texting.store.reviewClauses(day: key(now))["person:jamie lin"]?.typed == true, "clauses: a clause written from texts is marked typed")
        try texting.forget(date(3, 9, 0), date(3, 9, 30), now: now)
        check(try texting.store.reviewClauses(day: key(now))["person:jamie lin"] == nil, "forget: a text forgotten takes its thread's clause with it")
    }
}

// MARK: perf bounds (perf pass 10/03)

extension DayReviewChecks {
    static func ms(_ start: CFAbsoluteTime) -> Double { (CFAbsoluteTimeGetCurrent() - start) * 1000 }
    static let budget = Double(ProcessInfo.processInfo.environment["DAY_REVIEW_BUDGET_MS"] ?? "") ?? 5

    /// A full synthetic day (about 8 hours, a few thousand actions, notes on every moment): the review's cost on a Today
    /// read once cached, a writer pass with nothing due, and the hero card's refresh after a clause is saved.
    static func bench() async throws {
        let f = try Fixture("bench")
        let now = date(3, 18, 30)
        let apps: [(String, String, String, String, String?)] = [
            (ghostty.0, ghostty.1, "~/daydream", "", nil),
            (chrome.0, chrome.1, "Fix Messages drafts by samrivera · Pull Request #12 · acme/daydream", "https://github.com", "https://github.com/acme/daydream/pull/12"),
            (terminal.0, terminal.1, "~/daydream — swift build", "", nil),
            ("Xcode", "com.apple.dt.Xcode", "DayReview.swift — DayDream", "", nil),
            (slack.0, slack.1, "#launch - Fixture", "", nil),
            (chrome.0, chrome.1, "Fixture talk number %d - YouTube", "https://www.youtube.com", "https://www.youtube.com/watch?v=bench%d"),
            (chrome.0, chrome.1, "Fixture essay %d - Example Blog", "https://blog.example.com", "https://blog.example.com/essay-%d"),
            ("Notes", "com.apple.Notes", "Launch day plan", "", nil),
        ]
        var t = date(3, 9, 0), i = 0
        let seedStart = CFAbsoluteTimeGetCurrent()
        while t < date(3, 17, 30) {
            let a = apps[(i * 5 + i / 3) % apps.count]
            let title = a.2.contains("%d") ? String(format: a.2, i % 7) : a.2
            let page = a.4.map { $0.contains("%d") ? String(format: $0, i % 7) : $0 }
            let minutes = Double(2 + (i * 7) % 5)
            var ids = [String](), at = t, first = true
            let stop = t.addingTimeInterval(minutes * 60)
            while at < stop {
                f.n += 1
                var e = Evidence(id: String(format: "dr-%05d", f.n), at: iso(at), kind: first ? "window.changed" : "mouse.click", app: a.0, bundle: a.1, title: title, url: a.3, synthetic: true)
                e.page = page; first = false
                if try f.store.ingest(e, now: at.addingTimeInterval(1)) { ids.append(e.id) }
                at = at.addingTimeInterval(8)
            }
            t = stop.addingTimeInterval(i % 9 == 8 ? 25 * 60 : 15)
            i += 1
        }
        try f.notes(now)
        let day = key(now)
        print(String(format: "PERF bench day: %d actions seeded in %.1fs", f.n, ms(seedStart) / 1000))

        // 1. A Today read: the first builds the review, the next ones (nothing new) reuse it.
        var s0 = CFAbsoluteTimeGetCurrent()
        _ = try f.store.dayLevels(day: day, timezone: zone, now: now)
        let coldRead = ms(s0), coldReview = MemoryStore.lastReviewMillisecondsForChecks
        var hits = [Double](), reads = [Double]()
        for _ in 0..<5 {
            s0 = CFAbsoluteTimeGetCurrent()
            _ = try f.store.dayLevels(day: day, timezone: zone, now: now)
            reads.append(ms(s0)); hits.append(MemoryStore.lastReviewMillisecondsForChecks)
        }
        print(String(format: "PERF today read: first %.1f ms (review %.1f ms); cached reads %.1f ms median, review %.2f ms median / %.2f ms max",
                     coldRead, coldReview, reads.sorted()[2], hits.sorted()[2], hits.max() ?? 0))
        check((hits.max() ?? 99) <= budget, "perf: a cached review adds at most \(Int(budget)) ms to a Today read (\(String(format: "%.2f", hits.max() ?? 0)) ms; uncached \(String(format: "%.1f", coldReview)) ms)")
        // New records for the day: the next read builds it again and shows them.
        try f.window(chrome.0, chrome.1, "A brand new fixture video - YouTube", url: "https://www.youtube.com", page: "https://www.youtube.com/watch?v=new1",
                     at: date(3, 17, 40), minutes: 30)
        let fresh = try f.store.dayLevels(day: day, timezone: zone, now: now).review
        check(MemoryStore.lastReviewMillisecondsForChecks > (hits.max() ?? 0) && fresh.map { $0.threads.contains { $0.items.contains { $0.link?.title.contains("A brand new fixture video") == true } } } == true,
              "perf: new records for the day rebuild the cached review")

        // 2. Writer passes: the fake model writes what is due, then a pass with nothing due is remembered.
        let answers = Answers(Array(repeating: "{\"clause\":\"the swift build and its tests\"}", count: 12))
        let binding = LevelWriterBinding(store: f.store, generate: { _, _, _, _ in try await answers.next() })
        var written = 0, coldIdle = 0.0
        var firstIdle: LevelWriterBinding.ClauseStep?
        while written < 10 {
            // The pass that finds nothing due has to look at the day (and then remembers it).
            s0 = CFAbsoluteTimeGetCurrent()
            firstIdle = try await binding.reviewClause(timezone: zone, now: now)
            coldIdle = ms(s0)
            if firstIdle == nil { break }
            written += 1
        }
        var idle = [Double]()
        for k in 0..<5 {
            s0 = CFAbsoluteTimeGetCurrent()
            let none = try await binding.reviewClause(timezone: zone, now: now.addingTimeInterval(Double(k)))
            idle.append(ms(s0))
            if none != nil { check(false, "perf: nothing due stays nothing due") }
        }
        print(String(format: "PERF writer pass, nothing due: %d clauses written; first look %.1f ms, remembered %.2f ms median / %.2f ms max",
                     written, coldIdle, idle.sorted()[2], idle.max() ?? 0))
        check(written >= 1 && firstIdle == nil && (idle.max() ?? 99) <= budget,
              "perf: a writer pass with no clause due returns in under \(Int(budget)) ms (\(String(format: "%.2f", idle.max() ?? 0)) ms; first look \(String(format: "%.1f", coldIdle)) ms)")
        // ...and is looked at again after a change: new work on the project under a new title and 16 minutes make it due once more.
        let now2 = date(3, 19, 40)
        try f.window(terminal.0, terminal.1, "~/daydream — swift test --filter export", at: date(3, 19, 0), minutes: 20)
        try f.notes(now2)
        let later = try f.store.reviewClauseWork(timezone: zone, now: now2.addingTimeInterval(16 * 60))
        check(later.contains { $0.key == "code:daydream" }, "perf: a remembered \"nothing due\" ends when the day changes (\(later.map(\.key)))")

        // 3. A clause saved: the hero card's refresh reads the cached facts and the new clause, never the day.
        _ = try f.store.dayLevels(day: day, timezone: zone, now: now)
        s0 = CFAbsoluteTimeGetCurrent()
        _ = try f.store.dayLevels(day: day, timezone: zone, now: now)
        let fullRead = ms(s0)
        guard let target = later.first else { return }
        _ = try f.store.commitReviewClause(target, text: "the hero refresh fixture clause", now: now2.addingTimeInterval(16 * 60))
        var hero = [Double](), got: DayReviewFacts?
        for _ in 0..<5 {
            s0 = CFAbsoluteTimeGetCurrent()
            got = try f.store.cachedDayReview(day: day, timezone: zone)
            hero.append(ms(s0))
        }
        print(String(format: "PERF clause saved: hero refresh %.2f ms median / %.2f ms max; a full Today read %.1f ms", hero.sorted()[2], hero.max() ?? 0, fullRead))
        check(got?.clauses[target.key] == "the hero refresh fixture clause" && (hero.max() ?? 99) <= budget,
              "perf: after a clause is saved the hero card refreshes from the cache in under \(Int(budget)) ms, with the new clause")
        let viaRead = try f.store.dayLevels(day: day, timezone: zone, now: now).review
        check(viaRead?.clauses == got?.clauses && viaRead?.threads == got?.threads, "perf: the hero refresh matches a full read")
    }
}

/// The fake model's answers, in order; then it fails.
actor Evidences {
    var all = [String]()
    func add(_ e: String) { all.append(e) }
}
actor Answers {
    var list: [String]
    init(_ list: [String]) { self.list = list }
    func next() throws -> String {
        guard !list.isEmpty else { throw NSError(domain: "fixture-model", code: 2) }
        return list.removeFirst()
    }
}
