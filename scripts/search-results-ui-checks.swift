// DD-RECIPE: UI (headless: builds no window, hosts no view and never activates the app)
//
// claude/searchui-1005 (owner 10/04: a search for a contact did not show the texts that matched): how search results look and explain themselves.
//  1. Show the hit: a result's detail shows the matching lines in their real form (who, when, the words, the hit
//     highlighted) before any note line, also when summaries are off; code's "Read texts with …" goes when the texts show.
//  2. One time per row: a row's title is the conversation ("Jordan Lane", with a small "Texts" label), never a time; its
//     one time is the matching line's.
//  3. Snippets: the matching message or typed line, never "Line in …" or "Read texts with …"; a row found only by the
//     contact's name shows the conversation's latest message, never the name; a search typed in Messages' own search
//     field reads "Searched Messages for “rivera”", never "Texts · Messages".
//  4. Merge: hits of one conversation within a few minutes are one row with the count and the first hit; a conversation's
//     quiet moment ("Read texts with Sam Rivera.") folds into that day's row of the same conversation. Two moments that
//     each hold matching words stay two rows (search is flat moments), and nothing folds across days.
//  5. The moment detail's What happened folds back-to-back clicks in one app and site into one line with a count.
// Model: RecallModel over a temp MemoryStore (synthetic evidence under DD_CHECK_OUT or TMPDIR) with fake typed, metadata
// and note searches. Synthetic data only: no app, no permissions, no recording, no window, no pasteboard, never real history.
import AppKit
import Foundation
@testable import MemoryCore
@testable import MemoryUI

@main @MainActor enum SearchResultsUIChecks {
    static var failures = 0, passes = 0
    static func check(_ ok: Bool, _ name: String, _ got: @autoclosure () -> String = "") {
        if ok { passes += 1; print("PASS " + name) } else {
            failures += 1
            fflush(stdout)
            FileHandle.standardError.write(Data(("FAIL: " + name + (got().isEmpty ? "" : " (got: " + got() + ")") + "\n").utf8))
        }
    }
    static func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) { check(got == want, name, "\(got)") }

    static let zone = "America/Los_Angeles"
    static let la = TimeZone(identifier: zone)!
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = la; return c }
    static func d(_ day: Int, _ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: h, minute: m))! }
    static let clock = d(22, 16, 24)
    static let root: URL = {
        let base = ProcessInfo.processInfo.environment["DD_CHECK_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("claude-searchui-\(getpid())", isDirectory: true)
        return base.appendingPathComponent("search-results-ui", isDirectory: true)
    }()

    @discardableResult
    static func wait(_ seconds: Double = 8, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }
    static func pump(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    static func main() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 180) {
            FileHandle.standardError.write(Data("FAIL: search-results-ui watchdog expired\n".utf8)); exit(2)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        check(NSApp == nil, "checks run without constructing NSApplication")
        try? FileManager.default.removeItem(at: root)
        do {
            try modelChecks()
        } catch { check(false, "check setup", "\(error)") }
        foldUnits()
        evidenceUnits()
        clickFold()
        overflowUnits()
        sourceChecks()
        check(NSApp == nil, "model checks never construct an app or window")
        try? FileManager.default.removeItem(at: root)
        if failures > 0 {
            FileHandle.standardError.write(Data("FAIL: \(failures) search-results-ui check(s) failed\n".utf8)); exit(1)
        }
        print("PASS search-results-ui-checks: \(passes) checks; matching lines with who and when, one time per row, no template snippets, merged hits")
        exit(0)
    }

    // MARK: - Fixture

    static let messages = (app: "Messages", bundle: "com.apple.MobileSMS")
    static let mail = (app: "Mail", bundle: "com.apple.mail")

    static func item(_ store: MemoryStore, _ id: String) throws -> MemoryItem? {
        try store.searchActionItem(id, now: clock)
    }

    static func modelChecks() throws {
        let home = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        var ids: [String: String] = [:]
        func ingest(_ name: String, _ at: Date, _ app: (app: String, bundle: String), _ title: String) throws {
            let id = "e-" + name
            _ = try store.ingest(Evidence(id: id, at: iso(at), kind: "window.changed", app: app.app, bundle: app.bundle, title: title, synthetic: true), now: clock)
            ids[name] = id
        }
        // Today: a conversation with Jordan Lane from 11:39 to 12:30; the person typed two texts with "quote" at 12:18 and
        // 12:20 (the typed pass stands in for the sealed words), and one without at 11:50.
        try ingest("j1", d(22, 11, 39), messages, "Jordan Lane")
        try ingest("j2", d(22, 11, 50), messages, "Jordan Lane")
        try ingest("j3", d(22, 12, 18), messages, "Jordan Lane")
        try ingest("j4", d(22, 12, 20), messages, "Jordan Lane")
        try ingest("j5", d(22, 12, 30), messages, "Jordan Lane")
        // Today in Mail: an email whose note line matched ("quotes").
        try ingest("m1", d(22, 9, 0), mail, "Quarterly planning")
        try ingest("m2", d(22, 9, 4), mail, "Quarterly planning")
        // Yesterday: Sam Rivera at 8:00 PM (a text typed), and earlier a moment only reading the conversation (1:15 PM).
        try ingest("p1", d(21, 20, 0), messages, "Sam Rivera")
        try ingest("p2", d(21, 20, 1), messages, "Sam Rivera")
        try ingest("p3", d(21, 13, 15), messages, "Sam Rivera")
        try ingest("p4", d(21, 13, 16), messages, "Sam Rivera")
        // Yesterday 10:00 AM: Messages' own search field (the typed pass says so).
        try ingest("s1", d(21, 10, 0), messages, "Messages")
        // Sat 19: only reading Sam Rivera's texts.
        try ingest("q1", d(19, 18, 0), messages, "Sam Rivera")
        try ingest("q2", d(19, 18, 1), messages, "Sam Rivera")

        func items(_ names: [String]) throws -> [MemoryItem] { try names.compactMap { try item(store, ids[$0]!) } }
        let nothing = try store.searchResult(MemorySearchQuery("zzqqxx-nothing", limit: 50), now: clock)
        let browser = ActivityBrowser(calendar: cal)
        browser.now = { clock }
        browser.summaries = SummaryAvailability(provider: .local, busy: false)
        browser.loadCanonicalDay = { day, cursor in try store.dayLayers(day: day, timezone: zone, after: cursor, limit: 200, now: clock) }
        browser.searchCanonicalQuery = { _ in nothing }
        let model = browser.recallModel
        browser.recallPresented = true

        // MARK: "quote"
        let quoteTyped = try items(["j3", "j4"])
        check(quoteTyped.count == 2, "fixture: two typed texts to Jordan Lane", "\(quoteTyped.map(\.id))")
        let jordan = OwnerTypedPlace(label: "Texts", place: "Jordan Lane")
        let msg1 = "Any word on the quotes yet? Happy to help, or I can wait for Casey"
        let msg2 = "also did the quote deck go out"
        browser.searchOwnerTyped = { _ in
            OwnerTypedSearchResult(items: quoteTyped, snippets: [ids["j3"]!: msg1, ids["j4"]!: msg2],
                                   places: [ids["j3"]!: jordan, ids["j4"]!: jordan],
                                   lines: [ids["j3"]!: msg1, ids["j4"]!: msg2])
        }
        // The moment's texts as the timeline detail reads them (the verified owner source): one more text at 12:30.
        func text(_ id: String, _ at: Date, _ words: String, _ action: String) -> OwnerSourcePreview {
            OwnerSourcePreview(id: id, actionIDs: [action], at: iso(at), runID: "run-" + id, parts: [OwnerSourcePart(actionID: action, text: words, state: "submitted")],
                               state: "submitted", lead: "", readAt: clock, disclosureRevision: "r", expiresAt: nil)
        }
        let texts = [text("x1", d(22, 12, 30), "you around later?", ids["j5"]!), text("x2", d(22, 12, 18), msg1, ids["j3"]!),
                     text("x9", d(22, 12, 19), "old words", ids["j3"]!)]
        let expired = OwnerSourcePreview(id: "x8", actionIDs: [ids["j4"]!], at: iso(d(22, 12, 20)), runID: "run-x8",
                                         parts: [OwnerSourcePart(actionID: ids["j4"]!, text: "gone by now", state: "submitted")], state: "submitted",
                                         lead: "", readAt: clock, disclosureRevision: "r", expiresAt: Date().addingTimeInterval(-60))
        browser.loadOwnerSourcePreviews = { want in (texts + [expired]).filter { !Set($0.actionIDs).isDisjoint(with: want) } }
        let mailAction = ids["m1"]!
        browser.searchNotes = { _ in
            [NoteHit(level: "line", text: "Asked Casey Morgan about the quotes for the hall", inTitle: "Quotes request with Casey Morgan",
                     at: iso(d(22, 9, 0)), day: "2026-09-22", open: "moment:mail", actionID: mailAction)]
        }
        browser.query = "quote"
        model.retry()
        let quoteSettled = wait {
            !model.busy && model.result != nil && model.displayRows.count >= 2 && model.displayRows.allSatisfy { $0.moment != nil }
        }
        pump(0.2)
        check(quoteSettled, "quote: the search settles with every hit in its moment", "rows \(model.displayRows.map { $0.title + "|" + $0.id })")
        let rows = model.displayRows
        let lane = rows.first { $0.itemIDs.contains(ids["j3"]!) }
        check(lane != nil, "quote: the Jordan Lane texts are found")
        if let lane {
            equal(lane.title, "Jordan Lane", "quote: the row's title is the conversation, not \"Texts · Jordan Lane · 12:18 PM\"")
            equal(lane.kindLabel, "Texts", "quote: \"Texts\" is a small label beside the name")
            check(lane.title.range(of: #"\d:\d\d"#, options: .regularExpression) == nil, "quote: no time in the title")
            let line = model.rowLine(lane)
            equal(line.text, msg1, "quote: the snippet is the first matching text, not a note or a template")
            equal(line.at, d(22, 12, 18), "quote: the row's one time is the first matching line's (12:18 PM), not the moment's start (11:39 AM)")
            equal(lane.time, d(22, 12, 18), "quote: the row sorts by that same time")
            equal(line.count, 2, "quote: two matching texts in one conversation are one row with the count")
            equal(RecallResultRow.countText(line.count), "2 matches", "quote: the count reads \"2 matches\"")
            equal(rows.filter { $0.title == "Jordan Lane" }.count, 1, "quote: one row for the conversation")
            // The detail: the texts, who and when, before any note line.
            let hitsOnly = RecallModel.evidence(texts: [], hits: model.hitLines(lane), terms: model.terms)
            equal(hitsOnly.map(\.who), ["You", "You"], "quote detail: each matching line says who wrote it")
            equal(hitsOnly.map(\.at), [d(22, 12, 18), d(22, 12, 20)], "quote detail: each matching line has its own time, in order")
            equal(hitsOnly.map(\.text), [msg1, msg2], "quote detail: the texts in their real form")
            check(hitsOnly.allSatisfy(\.matched), "quote detail: both lines hold the match (highlighted)")
            model.select(lane.id)
            check(wait { model.evidence[lane.moment?.id ?? ""] != nil }, "quote detail: the moment's texts are read for the selected result")
            let evidence = model.evidenceLines(lane)
            equal(evidence.map(\.text), [msg1, "old words", msg2, "you around later?"],
                  "quote detail: the moment's texts and the matching ones, in time order; an expired text is left out")
            equal(evidence.map(\.matched), [true, false, true, false], "quote detail: only the matching texts are highlighted")
            equal(RecallEvidence.caption(evidence[0], timeZone: la), "You \u{00B7} 12:18 PM", "quote detail: caption is who and when")
            let reading = [MomentBullet(text: "Read texts with Jordan Lane."), MomentBullet(text: "Asked about the quote status.")]
            equal(RecallModel.noteLines(reading, evidence: evidence).map(\.text), ["Asked about the quote status."],
                  "quote detail: code's \"Read texts with …\" gives way to the texts themselves")
            equal(RecallModel.noteLines(reading, evidence: []).count, 2, "quote detail: without texts, the note keeps every line")
            let marked = RecallText.highlighted(msg1, terms: model.terms)
            check(marked.runs.contains { $0.inlinePresentationIntent == .stronglyEmphasized && String(marked[$0.range].characters).lowercased() == "quote" },
                  "quote detail: the hit itself is the only emphasised run")
        }
        let mailRow = rows.first { $0.itemIDs.isEmpty && $0.note != nil }
        check(mailRow != nil, "quote: the Mail moment found by its note line has a row")
        if let mailRow {
            let line = model.rowLine(mailRow)
            check(!line.text.hasPrefix("Line in"), "quote: no \"Line in …\" snippet", line.text)
            equal(line.text, "Asked Casey Morgan about the quotes for the hall", "quote: a note-only row shows the note line that matched")
            check(mailRow.title != "Asked Casey Morgan about the quotes for the hall", "quote: the note line is the second line, not the title")
            equal(line.at, d(22, 9, 0), "quote: the note row's time is the line's")
        }

        // MARK: "rivera"
        let riveraTyped = try items(["p1", "p2", "s1"])
        check(riveraTyped.count == 3, "fixture: Rivera typed rows", "\(riveraTyped.map(\.id))")
        let rivera = OwnerTypedPlace(label: "Texts", place: "Sam Rivera")
        let text1 = "see you at the trailhead at 9"
        browser.searchOwnerTyped = { _ in
            OwnerTypedSearchResult(items: riveraTyped,
                                   // p1: a row whose words were all withheld (no snippet); p2: found by the name, its words its own.
                                   snippets: [ids["p1"]!: "", ids["p2"]!: text1, ids["s1"]!: "rivera"],
                                   places: [ids["p1"]!: rivera, ids["p2"]!: rivera, ids["s1"]!: OwnerTypedPlace(label: "Messages", place: "", search: true)],
                                   lines: [ids["p2"]!: text1, ids["s1"]!: "rivera"], byName: [ids["p1"]!, ids["p2"]!])
        }
        let readYesterday = ids["p3"]!, readSaturday = ids["q1"]!
        browser.searchNotes = { _ in
            [NoteHit(level: "line", text: "Read texts with Sam Rivera.", inTitle: "Texts with Sam Rivera", at: iso(d(21, 13, 15)), day: "2026-09-21",
                     open: "moment:p3", actionID: readYesterday),
             NoteHit(level: "line", text: "Read texts with Sam Rivera.", inTitle: "Texts with Sam Rivera", at: iso(d(19, 18, 0)), day: "2026-09-19",
                     open: "moment:q1", actionID: readSaturday)]
        }
        browser.query = "rivera"
        model.retry()
        let riveraSettled = wait { !model.busy && model.result != nil && model.displayRows.count >= 2 && model.displayRows.allSatisfy { $0.moment != nil } }
        pump(0.3)
        check(riveraSettled, "rivera: the search settles", "rows \(model.displayRows.map { $0.title + "|" + $0.dayKey })")
        let prows = model.displayRows
        let shown = prows.map { ($0.title, model.rowLine($0).text) }
        print("rivera rows: \(shown.map { $0.0 + " / " + $0.1 })")
        check(!shown.contains { $0.0.hasPrefix("Read texts with") || $0.1.hasPrefix("Read texts with") || $0.1.hasPrefix("Line in") },
              "rivera: no \"Read texts with …\" title and no \"Line in …\" snippet", "\(shown)")
        check(!shown.contains { $0.1 == "Sam Rivera" }, "rivera: never the contact's name as the snippet")
        check(!shown.contains { $0.0 == "Messages" || $0.0.hasPrefix("Texts \u{00B7}") }, "rivera: no \"Texts · Messages\" row")
        let search = prows.first { $0.itemIDs.contains(ids["s1"]!) }
        equal(search?.title, "Searched Messages for \u{201C}rivera\u{201D}", "rivera: a search typed in Messages' own field says so")
        check(search.map { model.rowLine($0).text.isEmpty } == true && search?.kindLabel == nil, "rivera: the search row has no second line and no Texts label")
        let yesterday = prows.filter { $0.dayKey == "2026-09-21" && $0.conversation == "Sam Rivera" }
        equal(yesterday.count, 1, "rivera: yesterday's quiet reading moment folds into the conversation's row")
        if let y = yesterday.first {
            equal(y.title, "Sam Rivera", "rivera: the conversation's row is titled by the name")
            equal(y.kindLabel, "Texts", "rivera: with the small Texts label")
            equal(model.rowLine(y).text, text1, "rivera: a row found by the name shows the conversation's latest real message")
            equal(model.rowLine(y).at, d(21, 20, 1), "rivera: and that message's time")
            check(y.itemIDs.contains(readYesterday) || y.folded.contains { $0.actionIDs.contains(readYesterday) },
                  "rivera: the folded moment stays reachable from the row")
            let ev = model.evidenceLines(y)
            equal(ev.map(\.text), [text1], "rivera detail: the message is the evidence (the withheld row shows nothing, never the name)")
            check(ev.first?.who == "You" && ev.first?.matched == false, "rivera detail: who wrote it; found by the name, so nothing in it is highlighted")
        }
        check(!model.bestMatchShown, "rivera: code's \"Read texts with …\" line never makes a Best match", "\(model.sectionTitles)")
        let saturday = prows.filter { $0.dayKey == "2026-09-19" }
        equal(saturday.count, 1, "rivera: Saturday's reading moment stays its own row (nothing folds across days)")
        if let s = saturday.first {
            equal(s.title, "Sam Rivera", "rivera: Saturday's row reads as the conversation, not \"Read texts with Sam Rivera.\"")
            check(!model.rowLine(s).text.hasPrefix("Read texts with") && !model.rowLine(s).text.hasPrefix("Line in"),
                  "rivera: Saturday's row has no filler snippet", model.rowLine(s).text)
        }

        // MARK: Open (claude/searchui-1005 follow-up, owner 10/04): no pushed detail; Return and a double-click show the
        // result in context, in its own day with the moment selected and open, and close search.
        if let open = model.displayRows.first(where: { $0.moment != nil && $0.dayKey == "2026-09-21" }), let om = open.moment {
            model.select(open.id)
            check(!model.menuItems.contains { $0.id == .openMoment }, "open: no Open Moment item (there is no pushed detail)")
            check(model.menuItems.contains { $0.id == .showInToday }, "open: Show in <Day> stays in the Actions menu")
            equal(RecallModel.openTitle, "Show in Context", "open: the Return hint reads Show in Context")
            model.openMoment()
            pump(0.1)
            check(!browser.recallVisible && !browser.recallPresented && browser.query.isEmpty, "open: Return closes search")
            equal(browser.focusedDay, "2026-09-21", "open: Return opens the result's own day")
            check(browser.selectedMomentID == om.id && browser.expandedMomentID == om.id, "open: with its moment selected and open")
            browser.focusedDay = nil; browser.selectedMomentID = nil; browser.expandedMomentID = nil; browser.reference = nil
        } else { check(false, "open: a moment row from yesterday") }

        // MARK: Hits not yet in a moment: one conversation within five minutes is one row; further apart, two.
        let browser2 = ActivityBrowser(calendar: cal)
        browser2.now = { clock }
        browser2.searchCanonicalQuery = { _ in nothing }
        browser2.searchNotes = { _ in [] }
        let loose = try items(["j2", "j3", "j4"])
        browser2.searchOwnerTyped = { _ in
            OwnerTypedSearchResult(items: loose, snippets: [ids["j2"]!: "quote one", ids["j3"]!: msg1, ids["j4"]!: msg2],
                                   places: [ids["j2"]!: jordan, ids["j3"]!: jordan, ids["j4"]!: jordan])
        }
        let model2 = browser2.recallModel
        browser2.recallPresented = true
        browser2.query = "quote"
        model2.retry()
        check(wait { !model2.busy && model2.result != nil && !model2.displayRows.isEmpty }, "loose: the search settles")
        pump(0.2)
        let lrows = model2.displayRows
        check(lrows.count == 2, "loose: 12:18 and 12:20 share a row; 11:50 is its own", "\(lrows.map { $0.itemIDs })")
        if let merged = lrows.first(where: { $0.hits.count == 2 }) {
            equal(model2.rowLine(merged).count, 2, "loose: the merged row shows the count")
            equal(model2.rowLine(merged).text, msg1, "loose: and the first hit")
            equal(model2.rowLine(merged).at, d(22, 12, 18), "loose: at the first hit's time")
            check(!model2.menuItems(for: merged).isEmpty, "loose: the merged row keeps its Actions menu")
            check(!model2.menuItems(for: merged).contains { $0.id == .forget }, "loose: a merged row never offers Forget This Action for one of its hits")
            check(!model2.menuItems(for: merged).contains { $0.id == .openMoment }, "loose: a hit row has no Open Moment item either")
        } else { check(false, "loose: a merged row") }
        equal(Set(lrows.flatMap(\.itemIDs)), Set(loose.map(\.id)), "loose: every hit stays reachable")
        browser.query = ""; browser.recallPresented = false
        browser2.query = ""; browser2.recallPresented = false
    }

    // MARK: - Fold rules, hand-built rows

    static func slice(_ id: String, day: Int, _ h: Int, _ m: Int, title: String, live: LiveMoment? = nil, actions: [String]) -> MomentSlice {
        MomentSlice(id: id, dayKey: String(format: "2026-09-%02d", day), start: d(day, h, m), end: d(day, h, m + 2), title: title, subject: title,
                    firstBullet: nil, bullets: [], apps: ["Messages"], primaryBundle: messages.bundle, bundles: [messages.bundle], sites: [],
                    actionIDs: actions, actionCount: actions.count, clusters: [], summary: .summariesOff, hasCorrection: false,
                    primaryApp: "Messages", live: live)
    }

    static func foldUnits() {
        let live = LiveMoment(label: "Texts with Sam Q", kind: "texts", sends: [], seconds: 60, idle: false, communication: true)
        equal(RecallModel.conversationName(slice("a", day: 22, 10, 0, title: "Anything", live: live, actions: [])), "Sam Q",
              "fold: a moment's conversation is its thread's name")
        equal(RecallModel.conversationName(slice("b", day: 22, 10, 0, title: "Texts with Sam Q", actions: [])), "Sam Q",
              "fold: or its Messages title by code")
        var other = slice("c", day: 22, 10, 0, title: "Texts with Sam Q", actions: [])
        other = MomentSlice(id: "c", dayKey: other.dayKey, start: other.start, end: other.end, title: "Texts with Sam Q", subject: "", firstBullet: nil,
                            bullets: [], apps: ["Notes"], primaryBundle: "com.apple.Notes", bundles: ["com.apple.Notes"], sites: [], actionIDs: [],
                            actionCount: 0, clusters: [], summary: .summariesOff, hasCorrection: false)
        check(RecallModel.conversationName(other) == nil, "fold: a non-Messages moment titled like one is no conversation")
        // Two moments of one conversation, the same day, each with matching words: two rows (flat moments).
        func row(_ m: MomentSlice, words: String?) -> RecallRow {
            var r = RecallRow(id: m.id, kind: .moment(m), hits: [], dayKey: m.dayKey, day: cal.startOfDay(for: m.start), time: m.start, latest: m.end)
            r.conversation = "Sam Q"
            if let words {
                let item = MemoryItem(id: "h-" + m.id, evidence: Evidence(id: "h-" + m.id, at: iso(m.start), kind: "window.changed", app: "Messages",
                                                                         bundle: messages.bundle, title: "Sam Q", synthetic: true),
                                      summary: "", actionState: "", inference: false, generatedAt: "", coverageThrough: "", revision: "", writer: "")
                r.hits = [item]; r.typed = [item.id: words]
            }
            return r
        }
        let a = row(slice("m1", day: 22, 10, 0, title: "Texts with Sam Q", actions: ["h-m1"]), words: "the quote")
        let b = row(slice("m2", day: 22, 10, 3, title: "Texts with Sam Q", actions: ["h-m2"]), words: "quote again")
        let quiet = row(slice("m3", day: 22, 14, 0, title: "Texts with Sam Q", actions: ["x"]), words: nil)
        let otherDay = row(slice("m4", day: 21, 14, 0, title: "Texts with Sam Q", actions: ["y"]), words: nil)
        let out = RecallModel.fold([a, b, quiet, otherDay], window: RecallModel.mergeWindow)
        equal(out.map(\.id), ["m1", "m2", "m4"], "fold: moments with words stay apart, the quiet one folds, another day's stays")
        equal(out.first?.folded.map(\.id), ["m3"], "fold: the quiet moment folds into the day's first row with words")
    }

    // MARK: - Evidence merge

    static func evidenceUnits() {
        let hit = RecallHitLine(id: "a2", at: d(22, 12, 18), who: "You", text: "…word on the quotes yet…", typed: true, matched: true)
        let texts = [(id: "p1", at: Optional(d(22, 12, 18)), text: "Any word on the quotes yet? Happy to help", draft: false, actionIDs: ["a2"]),
                     (id: "p2", at: Optional(d(22, 12, 25)), text: "ok  thanks", draft: false, actionIDs: ["a3"]),
                     (id: "p3", at: Optional(d(22, 12, 26)), text: "never sent quote", draft: true, actionIDs: ["a4"])]
        let lines = RecallModel.evidence(texts: texts, hits: [hit], terms: ["quote"])
        equal(lines.map(\.id), ["p1", "p2", "p3"], "evidence: the moment's texts stand for the hits they hold, in time order")
        equal(lines.map(\.who), ["You", "You", "Your draft"], "evidence: who wrote each, a draft said as one")
        equal(lines.map(\.matched), [true, false, true], "evidence: only lines with the query are marked")
        equal(lines[1].text, "ok thanks", "evidence: whitespace collapsed, words verbatim")
        let many = (0..<12).map { n in (id: "t\(n)", at: Optional(d(22, 10, n)), text: n == 1 ? "the quote" : "line \(n)", draft: false, actionIDs: ["x\(n)"]) }
        let capped = RecallModel.evidence(texts: many, hits: [], terms: ["quote"])
        check(capped.count == RecallModel.evidenceLimit && capped.contains { $0.id == "t1" }, "evidence: capped, and the matching line always stays",
              "\(capped.map(\.id))")
        equal(RecallModel.evidence(texts: [], hits: [hit], terms: ["quote"]).map(\.text), [hit.text], "evidence: without texts, the matching lines are the evidence")
    }

    // MARK: - What happened: back-to-back clicks

    static func clickFold() {
        func click(_ id: String, _ when: Date, page: String) -> CanonicalAction {
            ActionProjection.make(Evidence(id: id, at: iso(when), kind: "mouse.click", app: "ChatGPT", bundle: "com.openai.chat", title: "ChatGPT",
                                           url: "https://preview.example.test/" + page, synthetic: true))
        }
        let actions = (0..<15).map { click("c\($0)", d(22, 15, 2 + $0 / 5), page: "p\($0)") }
        let raw = OwnerSourceMomentProjection.history(actions, previews: [])
        let lines = MomentHistoryCondense.lines(raw, actions: actions, timeZone: la)
        print("click lines: \(lines.map { $0.title + " | " + $0.detail })")
        equal(lines.count, 1, "clicks: fifteen back-to-back clicks in one app and site are one line")
        if let l = lines.first {
            check(l.detail.contains("15 times") && l.detail.contains("Clicked") && l.detail.contains("\u{2013}"), "clicks: with the count and time range", l.detail)
            equal(Set(l.actionIDs), Set(actions.map(\.id)), "clicks: every click stays reachable")
        }
        let typed = ActionProjection.make(Evidence(id: "t", at: iso(d(22, 15, 3)), kind: "keyboard.text_input", app: "ChatGPT", bundle: "com.openai.chat",
                                                   title: "ChatGPT", url: "https://preview.example.test/q", text: "hello", synthetic: true))
        let mixed = Array(actions.prefix(3)) + [typed] + Array(actions.suffix(3))
        let mixedLines = MomentHistoryCondense.lines(OwnerSourceMomentProjection.history(mixed, previews: []), actions: mixed, timeZone: la)
        check(mixedLines.count >= 2, "clicks: a typed line between runs keeps its own line", "\(mixedLines.map { $0.title + " | " + $0.detail })")
    }

    // MARK: - "+N more" opens inline (claude/searchui-1005 follow-up, owner 10/04)

    static func overflowUnits() {
        let texts = (1...9).map { "text \($0) about the trailhead" }
        let thread = FocusAppCard.TextThread(name: "Sam Rivera", texts: texts, actionIDs: ["a1"], latest: "2026-09-21T20:01:00Z")
        equal(thread.more, 6, "more: nine texts show three and hide six")
        equal(FocusAppCard.moreLine(thread.more), "+6 more", "more: the closed line reads +6 more")
        equal(thread.visible(expanded: false), Array(texts.prefix(3)), "more: closed, the first three texts")
        equal(thread.visible(expanded: true), texts, "more: opened, every text inline, in order")
        equal(FocusAppCard.overflowToggle(FocusAppCard.moreLine(thread.more), expanded: false), "+6 more", "more: the link reads +6 more")
        equal(FocusAppCard.overflowToggle(FocusAppCard.moreLine(thread.more), expanded: true), "Show less", "more: opened, it reads Show less")
        equal(FocusAppCard.overflowToggle(FocusAppCard.moreLine(0), expanded: false), nil, "more: nothing hidden, no link")
        let short = FocusAppCard.TextThread(name: "Jordan Lane", texts: ["one", "two"], actionIDs: ["a2"], latest: "2026-09-22T12:18:00Z")
        equal(short.visible(expanded: true), ["one", "two"], "more: a short conversation is the same either way")
        let quotes = ["first", "second", "third", "fourth", "fifth"]
        equal(FocusAppCard.visibleMessages(quotes, expanded: false), ["first", "second"], "earlier: closed, the first two messages")
        equal(FocusAppCard.visibleMessages(quotes, expanded: true), quotes, "earlier: opened, every message inline")
        equal(FocusAppCard.overflowToggle(FocusAppCard.earlierLine(quotes.count), expanded: false), "+3 earlier messages", "earlier: the link reads +3 earlier messages")
        equal(FocusAppCard.overflowToggle(FocusAppCard.earlierLine(quotes.count), expanded: true), "Show less", "earlier: opened, it reads Show less")

        // A collapsed card that names one of several people or threads counts the rest (owner 10/04).
        let texted = ["Texted Sam Rivera about the Sunday hike.", "Texted Jordan Lane about the quote deck.", "Texted Morgan Park to confirm dinner."]
        equal(FocusAppCard.peopleLine(texted), "Texted Sam Rivera + 2 others", "people: three conversations read the newest + 2 others")
        equal(FocusAppCard.peopleLine(Array(texted.prefix(2))), "Texted Sam Rivera + 1 other", "people: two read + 1 other")
        equal(FocusAppCard.peopleLine(["Texted Sam Rivera about the hike.", "Texted Sam Rivera the trail map."]), nil,
              "people: one conversation keeps its own line")
        equal(FocusAppCard.peopleLine(["Asked Claude to tidy the notes.", "Asked ChatGPT about trail maps."]), "Asked Claude + 1 other",
              "people: the same rule for assistants asked")
        equal(FocusAppCard.peopleLine(["Asked Claude to tidy the notes.", "Asked Claude about trail maps."]), nil, "people: one assistant, no count")
        equal(FocusAppCard.peopleLine(["Texted Sam Rivera's group about Sunday.", "Texted +1 555 0100 the address."]), "Texted Sam Rivera + 1 other",
              "people: a possessive ends the name; a number is a thread too")
        equal(FocusAppCard.peopleLine(["Planned the Sunday hike.", "Texted Jordan Lane about the deck."]), nil, "people: a line naming no one stays")
        equal(FocusAppCard.peopleLine(["Texted Sam Rivera about Sunday.", "Asked Claude about trail maps."]), nil, "people: different actions are not counted together")
        let card = [MomentSlice(id: "c1", dayKey: "2026-09-22", start: d(22, 12, 0), end: d(22, 12, 20), title: "Texts", subject: "Texts",
                                firstBullet: texted[0], bullets: texted.map { MomentBullet(text: $0) }, apps: ["Messages"],
                                primaryBundle: messages.bundle, bundles: [messages.bundle], sites: [], actionIDs: ["c1a"], actionCount: 1,
                                clusters: [], summary: .ready(generatedAt: nil, local: true), hasCorrection: false, primaryApp: "Messages", live: nil)]
        equal(FocusAppCard.collapsedLine(card), "Texted Sam Rivera + 2 others", "people: the collapsed Texts card reads the newest person + 2 others")
    }

    /// The text of `name`'s declaration in `text`, up to the next top-level declaration.
    static func body(_ text: String, _ name: String) -> String {
        guard let start = text.range(of: name) else { return "" }
        let rest = text[start.upperBound...]
        let end = rest.range(of: "\n}\n")?.upperBound ?? rest.endIndex
        return String(rest[..<end])
    }

    // MARK: - Source

    static func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    static func sourceChecks() {
        let rows = source("Sources/MemoryUI/RecallRows.swift"), preview = source("Sources/MemoryUI/RecallPreview.swift")
        let detail = source("Sources/MemoryUI/RecallDetail.swift"), model = source("Sources/MemoryUI/RecallModel.swift")
        let panel = source("Sources/MemoryUI/RecallPanel.swift"), field = source("Sources/MemoryUI/RecallSearchField.swift")
        let expanded = source("Sources/MemoryUI/FocusListExpanded.swift"), kit = source("Sources/MemoryUI/DaydreamKitMoments.swift")
        check(!rows.isEmpty && !preview.isEmpty && !detail.isEmpty && !model.isEmpty, "sources read (run from the repo root)")
        for (name, text) in [("RecallRows", rows), ("RecallPreview", preview), ("RecallDetail", detail), ("RecallModel", model)] {
            let code = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && !$0.contains("///") }
            check(!code.contains { $0.contains("\"Line in ") }, "\(name): no \"Line in …\" template")
            check(!code.contains { $0.contains("typedContext") }, "\(name): no title with a time baked in")
            let boldText = code.filter { $0.contains("Text(") && ($0.contains("weight: .bold") || $0.contains("weight: .semibold") || $0.contains("weight: .medium")) }
            check(boldText.isEmpty, "\(name): no bold text but the search hit's highlight", boldText.joined(separator: " | "))
        }
        check(preview.contains("summary(m)\n                        ShowInContextButton { model.showInDay() }"), "the preview keeps Show in Context right under the note")
        // No pushed detail (owner 10/04): its views, state and keyboard hints are gone; Return is Show in Context.
        check(!detail.contains("struct RecallDetailView") && !detail.contains("struct RecallDetailBar") && detail.contains("struct RecallActionForgetModifier"),
              "no pushed detail view or bar; the Forget This Action confirmation stays")
        check(!panel.contains("RecallDetail") && !panel.contains("model.detailRow") && !panel.contains("\"Open Moment\""),
              "the panel draws no detail and no Open Moment hint")
        check(panel.contains("hint(RecallModel.openTitle, \"↩\", strong: true, enabled: true) { model.openMoment() }")
              && panel.contains("hint(\"Actions\", \"⌘K\""), "the bar's hints: Show in Context ↩, then Actions ⌘K")
        check(!model.contains("detailRowID") && !model.contains("func back()") && !model.contains("positionText")
              && !model.contains("title: \"Open Moment\""), "the model keeps no pushed-detail state and offers no Open Moment")
        check(field.contains("else { model.openMoment() }"), "Return in the field opens the selection in context")
        check(rows.contains("TapGesture(count: 2).onEnded { model.select(row.id); model.openMoment() }"), "a double-click opens the result in context")
        // "+N more" and "+N earlier messages" are links that open inline; person headings are regular weight.
        let threads = body(expanded, "struct TextThreadList"), toggle = body(expanded, "struct OverflowToggle")
        check(!threads.isEmpty && !threads.contains("weight:"), "Texts summary: the person's name and texts are regular weight", threads)
        check(threads.contains("Text(thread.title).font(.system(size: size))"), "Texts summary: the heading is a plain line")
        check(threads.contains("OverflowToggle(collapsed: FocusAppCard.moreLine(thread.more)") && threads.contains("thread.visible(expanded: expanded)")
              && !threads.contains("Text(more)"), "Texts summary: +N more is a link that opens the conversation's texts")
        check(expanded.contains("OverflowToggle(collapsed: FocusAppCard.earlierLine(messages.count), expanded: $quotesOpen")
              && expanded.contains("FocusAppCard.visibleMessages(messages, expanded: quotesOpen)") && !expanded.contains("Text(earlier)"),
              "card quotes: +N earlier messages is a link that opens them")
        check(toggle.contains("Button {") && toggle.contains(".buttonStyle(FocusLinkButtonStyle())") && !toggle.contains("weight:")
              && toggle.contains(".accessibilityValue(expanded ? \"Expanded\" : \"Collapsed\")"),
              "the overflow link is a Button (keyboard and VoiceOver), in the accent link style, never bold")
        check(kit.contains("Text(name).font(.system(size: 12.5)).lineLimit(1)") && kit.contains("Text(send).font(.system(size: 12)).foregroundStyle(.secondary)"),
              "What happened lines are regular weight")
        check(preview.contains("if !lines.isEmpty { RecallEvidence(") && preview.range(of: "RecallEvidence(")!.lowerBound < preview.range(of: "summary(m)\n")!.lowerBound,
              "the preview draws the evidence before the note")
    }
}
