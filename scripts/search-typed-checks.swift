// DD-RECIPE: UI (headless: builds no window, hosts no view and never activates the app)
//
// fix/search-1003: Recall finds what the person typed (owner, 2026-09-29: typed words are searchable on this Mac, in
// their own app). The owner's bug: a word sent in a text showed on the moment's detail page, but search said
// `No moments match "…"` with "Some recent moments may not show yet." under it.
//  - Control (the bug): with the metadata search only, and the index catching up, a typed word finds nothing.
//  - Fixed: with `searchOwnerTyped` wired as the app wires it (`MemoryStore.ownerTypedSearch` on the app's own store),
//    the same query (any case, a prefix) shows the moment, its row reads as the conversation ("Pat Quill", Texts, 2:29 AM)
//    and its subtitle is the typed snippet holding the query; Why it matched lists "You typed"; Show in Context opens
//    the moment's day. A row typed seconds ago is found at once. Nothing typed reaches the store's search result.
// Synthetic data, in-memory keys, a temp store under DD_CHECK_OUT or TMPDIR: no app, no window, no Keychain.
import AppKit
import Foundation
import MemoryCore
import MemoryUI

@main @MainActor enum SearchTypedChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String, _ got: @autoclosure () -> String = "") {
        if ok { print("PASS " + name) } else {
            failures += 1
            fflush(stdout)
            FileHandle.standardError.write(Data(("FAIL: " + name + (got().isEmpty ? "" : " (got: " + got() + ")") + "\n").utf8))
        }
    }
    static let zone = "America/Chicago"
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }
    static let root: URL = {
        let base = ProcessInfo.processInfo.environment["DD_CHECK_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("claude-search-typed-\(getpid())", isDirectory: true)
        return base.appendingPathComponent("search-typed", isDirectory: true)
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

    static func main() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
            FileHandle.standardError.write(Data("FAIL: search-typed watchdog expired\n".utf8)); exit(2)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        try? FileManager.default.removeItem(at: root)
        do { try modelChecks() } catch { check(false, "check setup", "\(error)") }
        check(NSApp == nil, "model checks never construct an app or window")
        try? FileManager.default.removeItem(at: root)
        if failures > 0 { FileHandle.standardError.write(Data("FAIL: \(failures) search-typed check(s) failed\n".utf8)); exit(1) }
        print("PASS search-typed-checks: typed words are found in Recall with their context and snippet, on this Mac only")
        exit(0)
    }

    static func modelChecks() throws {
        let home = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let now = Date()
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        var policy = try store.policy(); policy.captureText = true; policy.typedConsentVersion = 1; try store.updatePolicy(policy, now: now)
        try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore()))
        try store.acceptSafeTyping()
        try store.setUpTypedVault()
        func typed(_ id: String, _ text: String, _ seconds: Double, bundle: String, app: String) -> Evidence {
            var e = Evidence(id: id, at: iso(now.addingTimeInterval(-seconds)), kind: "keyboard.text_input", app: app, bundle: bundle,
                             title: "Untitled", text: text, synthetic: true)
            var unit = TypedUnitProvenance(runID: "run-" + id, part: 1, sealReason: "submit", startedAt: iso(now.addingTimeInterval(-seconds - 5)),
                                           keys: 40, edits: 0, withheld: 0)
            unit.surface = "text"; unit.field = "message"; unit.send = "detected"; unit.to = "Pat Quill"; unit.version = TypedUnitProvenance.sendFactsVersion
            e.captureProvenance = NativeCaptureProvenance(policyRevision: "r", classifierVersion: "sensitive-typing/v2+typed-scrub/v1", windowID: "w-" + id,
                                                          focusID: "f-" + id, checkedAt: iso(now), generation: 1, unit: unit)
            return e
        }
        // The moment around the text: the app in front a minute before, then the sent text. Public builds may not type in
        // Messages: TextEdit then stands in (same send facts).
        var place = ("com.apple.MobileSMS", "Messages")
        _ = try store.ingest(Evidence(id: "w1", at: iso(now.addingTimeInterval(-3 * 3600 - 60)), kind: "window.changed", app: place.1, bundle: place.0,
                                      title: "Messages", synthetic: true), now: now)
        if !(try store.ingest(typed("t1", "me and my pals are going to ZUX tmrw", 3 * 3600, bundle: place.0, app: place.1), now: now)) {
            place = ("com.apple.TextEdit", "TextEdit")
            _ = try store.ingest(Evidence(id: "w2", at: iso(now.addingTimeInterval(-3 * 3600 - 50)), kind: "window.changed", app: place.1, bundle: place.0,
                                          title: "Untitled", synthetic: true), now: now)
            check(try store.ingest(typed("t1", "me and my pals are going to ZUX tmrw", 3 * 3600, bundle: place.0, app: place.1), now: now),
                  "fixture: a sent text (TextEdit stands in for Messages in this build)")
        }
        print("search-typed fixture: typed row in \(place.1)")

        let browser = ActivityBrowser(calendar: cal)
        browser.now = { now }
        browser.summaries = SummaryAvailability(provider: .local, busy: false)
        browser.loadCanonicalDay = { day, cursor in try store.dayLayers(day: day, timezone: zone, after: cursor, limit: 200, now: now) }
        // The index is behind (the footer's "may not show yet"), as on the owner's Mac.
        browser.searchCanonicalQuery = { q in var r = try store.searchResult(q, now: now); r.status = "catching_up"; r.next = nil; r.partial = true; return r }
        browser.searchDirectPreview = { q in try store.directSearchPreview(q, now: now) }
        browser.reconcileSearchPreview = { q, ids, page in try store.reconcileDirectPreview(q, ids: ids, with: page, now: now) }
        let model = browser.recallModel
        browser.recallPresented = true

        func search(_ q: String) -> Bool {
            browser.query = q
            model.retry()
            let done = wait { !model.busy && model.result != nil && model.searchedText == q }
            RunLoop.main.run(until: Date().addingTimeInterval(0.3))
            _ = wait { !model.busy }
            return done
        }
        // Control: the bug.
        check(search("Zux"), "control: the search settles")
        check(model.showsNoResults && model.statusLine == RecallModel.catchingUpText,
              "control (the bug): without the typed pass a sent word finds nothing, and the footer says recent moments may not show",
              "rows \(model.displayRows.count) status \(model.statusLine ?? "nil")")

        // Fixed: wired as the app wires it.
        browser.searchOwnerTyped = { q in try store.ownerTypedSearch(q, now: now) }
        for q in ["Zux", "ZUX", "zux", "Zu"] {
            check(search(q), "typed: the search settles (\(q.count) letters)")
            let row = model.displayRows.first { $0.itemIDs.contains("t1") }
            check(row != nil && !model.showsNoResults, "typed: the sent text's row is found, any case or a prefix", "\(model.displayRows.map(\.id))")
            guard let row else { continue }
            let time = DaydreamFormat.time(timestamp(iso(now.addingTimeInterval(-3 * 3600)))!, cal.timeZone)
            // claude/searchui-1005 (owner 10/04): the title is the conversation ("Pat Quill", "Texts" as a small label);
            // the row's one time is the text's, beside it, never in the title.
            check(row.title == "Pat Quill" && row.kindLabel == "Texts", "typed: the row reads as the conversation, never a bare moment title", row.title)
            check(DaydreamFormat.time(model.rowLine(row).at ?? row.time, cal.timeZone) == time, "typed: the row's one time is the text's")
            let snippet = row.typed["t1"] ?? ""
            check(snippet.range(of: q, options: .caseInsensitive) != nil && snippet.contains("ZUX"), "typed: the row carries the snippet with the word as typed")
            check(model.matchSources(row).first == .typed, "typed: Why it matched leads with You typed", "\(model.matchSources(row))")
            check(row.moment?.actionIDs.contains("t1") == true || row.kind == .action, "typed: the row is the moment that holds the text (or the hit)")
        }
        // A row typed seconds ago, found at once.
        _ = try store.ingest(typed("t2", "see you at the narwhalpier", 3, bundle: place.0, app: place.1), now: now)
        check(search("narwhalpier") && model.displayRows.contains { $0.itemIDs.contains("t2") }, "fresh: a row typed seconds ago is found at once")
        // Show in Context opens the moment's day.
        check(search("zux"), "settles again")
        if let row = model.displayRows.first(where: { $0.itemIDs.contains("t1") }) {
            model.select(row.id)
            model.showInDay()
            let day = try DayScope.key(now.addingTimeInterval(-3 * 3600), timezone: zone), today = try DayScope.key(now, timezone: zone)
            check(browser.focusedDay == (day == today ? nil : day), "Show in Context: opens the text's own day", "\(browser.focusedDay ?? "today")")
            if let m = row.moment { check(browser.expandedMomentID == m.id, "Show in Context: opens that moment") }
        }
        // The shared metadata search (MCP, CLI) still has no typed words.
        check(try store.searchResult(MemorySearchQuery("zux"), now: now).items.isEmpty, "the metadata search never matches typed words")
    }
}
