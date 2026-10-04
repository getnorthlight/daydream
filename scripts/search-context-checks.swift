// DD-RECIPE: UI (headless: builds no window, hosts no view and never activates the app)
//
// Search in context (owner, 9/30): search lists individual moments, the detail offers no Find Related Moments, and
// Show in Context sits directly under the summary and runs search's Show in Today (`RecallModel.showInDay`), which
// opens the moment's own day with the moment selected and open. The timeline keeps its Find Related Moments.
//  - Model: RecallModel over a temp MemoryStore (synthetic evidence under DD_CHECK_OUT or TMPDIR), with a
//    `searchNotes` answering a note at every level. Rows are moments (or single hits) only: no block, day or week
//    note row, a line joins its moment, and two nearby X moments in Chrome (a timeline session) stay two rows.
//  - Actions: no Recall row, in the list or the pushed detail, offers Find Related Moments; the timeline's items do;
//    the moment detail's VoiceOver actions don't.
//  - Show in Context: from the pushed detail of a moment on another day, the day, selection, expansion and
//    reference are that moment's; search closes. The source places the button right under the summary in the
//    detail and the preview, wired to `model.showInDay()`, and search's rows never pass through the timeline's
//    `FocusListLayout` (its blocks and sessions).
// Synthetic data only: no app, no permissions, no recording, no window, no pasteboard.
import AppKit
import Foundation
import MemoryCore
import MemoryUI

@main @MainActor enum SearchContextChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String, _ got: @autoclosure () -> String = "") {
        if ok { print("PASS " + name) } else {
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
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("claude-search-context-\(getpid())", isDirectory: true)
        return base.appendingPathComponent("search-context", isDirectory: true)
    }()
    static let repo = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

    static func pump(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
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
            FileHandle.standardError.write(Data("FAIL: search-context watchdog expired\n".utf8)); exit(2)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        check(NSApp == nil, "checks run without constructing NSApplication")
        try? FileManager.default.removeItem(at: root)
        sourceChecks()
        do { try modelChecks() } catch { check(false, "check setup", "\(error)") }
        check(NSApp == nil, "model checks never construct an app or window")
        try? FileManager.default.removeItem(at: root)
        if failures > 0 {
            FileHandle.standardError.write(Data("FAIL: \(failures) search-context check(s) failed\n".utf8)); exit(1)
        }
        print("PASS search-context-checks: flat search rows, no Find Related in the detail, Show in Context routes to Show in Today")
        exit(0)
    }

    // MARK: - Model

    static func modelChecks() throws {
        let home = root.appendingPathComponent("store", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        var n = 0
        func moment(_ day: Int, _ h: Int, _ m: Int, _ app: String, _ bundle: String, _ title: String, url: String = "") throws {
            for k in 0..<2 {
                n += 1
                _ = try store.ingest(Evidence(id: "e\(n)", at: iso(d(day, h, m + k)), kind: "window.changed", app: app, bundle: bundle,
                                              title: title, url: url, synthetic: true), now: clock)
            }
        }
        let chrome = ("Google Chrome", "com.google.Chrome"), notes = ("Notes", "com.apple.Notes"), zed = ("Zed", "dev.zed.Zed")
        // Two X moments in Chrome three minutes apart with Notes between: the timeline may show them as one session.
        try moment(22, 10, 0, chrome.0, chrome.1, "Launch thread / X", url: "https://x.com")
        try moment(22, 10, 3, notes.0, notes.1, "Launch notes")
        try moment(22, 10, 6, chrome.0, chrome.1, "Launch replies / X", url: "https://x.com")
        try moment(22, 14, 0, zed.0, zed.1, "Launch checklist")
        try moment(21, 11, 0, zed.0, zed.1, "Launch plan draft")
        var found = try store.searchResult(MemorySearchQuery("launch", start: d(19, 0, 0), limit: 50), now: clock)
        found.items.sort { (timestamp($0.evidence.at) ?? .distantPast) > (timestamp($1.evidence.at) ?? .distantPast) }
        found.next = nil
        check(found.items.count >= 8, "fixture: hits for \"launch\" across two days", "\(found.items.count)")
        let planAction = found.items.first { $0.evidence.title == "Launch plan draft" }?.id ?? ""
        let checklistAction = found.items.first { $0.evidence.title == "Launch checklist" }?.id ?? ""

        // A note at every level for the query; only the moment's line and whole note may reach search's rows.
        let hits: [NoteHit] = [
            NoteHit(level: "week", text: "Launch week", inTitle: nil, at: iso(d(21, 0, 0)), day: "2026-09-21", open: "week:2026-W39"),
            NoteHit(level: "day", text: "Launch prep day", inTitle: nil, at: iso(d(22, 0, 0)), day: "2026-09-22", open: "day:2026-09-22"),
            NoteHit(level: "block", text: "Launch block", inTitle: nil, at: iso(d(22, 10, 0)), day: "2026-09-22", open: "block:b1"),
            NoteHit(level: "line", text: "Wrote the launch plan", inTitle: "Launch plan draft", at: iso(d(21, 11, 0)), day: "2026-09-21",
                    open: "moment:plan", actionID: planAction),
            NoteHit(level: "moment", text: "Launch checklist", inTitle: nil, at: iso(d(22, 14, 0)), day: "2026-09-22",
                    open: "moment:checklist", actionID: checklistAction),
        ]

        let browser = ActivityBrowser(calendar: cal)
        let source = store
        browser.now = { clock }
        browser.summaries = SummaryAvailability(provider: .local, busy: false)
        browser.loadCanonicalDay = { day, cursor in try source.dayLayers(day: day, timezone: zone, after: cursor, limit: 200, now: clock) }
        browser.searchCanonicalQuery = { _ in found }
        browser.searchNotes = { _ in hits }
        let model = browser.recallModel
        browser.recallPresented = true
        browser.query = "launch"
        model.retry()
        let settled = wait {
            !model.busy && model.result != nil && !model.displayRows.isEmpty
                && model.displayRows.allSatisfy { $0.moment != nil } && model.displayRows.contains { $0.note?.level == "line" }
        }
        pump(0.2)
        check(settled, "the search settles with every hit in its moment",
              "busy \(model.busy) rows \(model.displayRows.map(\.id)) notes \(model.noteHits.map(\.level))")
        let rows = model.displayRows

        // 1. Flat: individual moments only.
        check(model.noteHits.allSatisfy { RecallModel.momentNoteLevels.contains($0.level) },
              "search keeps a moment's line and whole note, never a block, day or week note", "\(model.noteHits.map(\.level))")
        check(rows.allSatisfy { $0.moment != nil || $0.kind == .action }, "every search row is one moment or one hit")
        check(!rows.contains { $0.id.hasPrefix("note:") }, "no note row")
        equal(Set(rows.map(\.id)).count, rows.count, "each moment is one row")
        let ids = Set(rows.compactMap { $0.moment?.actionIDs }.flatMap { $0 })
        check(found.items.allSatisfy { ids.contains($0.id) }, "every hit sits in its own moment's row")
        let xRows = rows.filter { $0.moment?.bundles == [chrome.1] && $0.moment?.sites.contains("x.com") == true }
        equal(xRows.count, 2, "two nearby X moments in Chrome (a timeline session) stay two search rows")
        check(rows.first { $0.note?.level == "line" }?.moment?.actionIDs.contains(planAction) == true,
              "a matching line joins its own moment's row")
        check(!model.showsNoResults, "moments found: no empty state")

        // 2. No Find Related Moments in search (list or detail); the timeline keeps it.
        check(!rows.contains { row in model.menuItems(for: row).contains { $0.id == .findRelated } }, "no search row's menu offers Find Related Moments")
        guard let other = rows.first(where: { $0.dayKey == "2026-09-21" }), let m = other.moment else {
            check(false, "a moment from another day is found"); return
        }
        model.select(other.id)
        // claude/searchui-1005 (owner 10/04): no pushed detail; Return shows the result in context.
        check(!model.menuItems.contains { $0.id == .findRelated }, "the result's Actions menu has no Find Related Moments")
        check(model.menuItems.contains { $0.id == .showInToday }, "the result keeps Show in <Day> (the path Show in Context runs)")
        check(!model.menuItems.contains { $0.id == .openMoment }, "no Open Moment item: there is no pushed detail to open")
        check(!browser.commandContext.canFindRelated, "the Moment menu's Find Related Moments is off while search shows a moment")
        let caps = MomentActions.Capabilities(browser: browser)
        check(MomentActions.items(for: m, context: .focusList, browser: caps).contains { $0.id == .findRelated },
              "the timeline's menus keep Find Related Moments")
        check(!MomentActions.items(for: m, context: .focusListDetail, browser: caps).contains { $0.id == .findRelated },
              "the pushed timeline detail removes Find Related from the shared action rules")
        check(DaydreamCommandContext.make(selection: m, context: .focusList, capabilities: caps, recallVisible: false).canFindRelated,
              "the timeline's valid selection keeps Find Related in the global menu and shortcut context")
        check(!DaydreamCommandContext.make(selection: m, context: .focusListDetail, capabilities: caps, recallVisible: false).canFindRelated,
              "the pushed timeline detail omits Find Related from the global menu and shortcut context")
        check(!FocusListExpanded.accessibilityActions(MomentActions.items(for: m, context: .focusList, browser: caps)).contains { $0.id == .findRelated },
              "a moment's detail offers no Find Related Moments to VoiceOver")

        // 3. Show in Context = Show in Today = Return (claude/searchui-1005: Open goes straight there): the moment's own
        // day, selected and open, and search closes.
        browser.selectedCanonicalActivity = "old-detail"
        let serial = browser.contextRevealSerial
        model.openMoment()
        pump(0.1)
        equal(browser.focusedDay, "2026-09-21", "Show in Context opens the moment's own day")
        equal(browser.selectedMomentID, m.id, "Show in Context keeps the moment selected")
        equal(browser.expandedMomentID, m.id, "Show in Context opens the moment's card")
        equal(browser.reference?.moments, [m.id], "Show in Context lights that moment")
        check(!browser.recallVisible && browser.query.isEmpty, "Show in Context closes search")
        check(browser.selectedCanonicalActivity == nil && browser.contextRevealSerial == serial + 1,
              "Show in Context dismisses a stale pushed detail even when the old navigation ID is unchanged")

        // A moment from today: today (focusedDay nil), selected.
        browser.focusedDay = nil; browser.selectedMomentID = nil; browser.expandedMomentID = nil; browser.reference = nil
        browser.query = "launch"
        model.retry()
        wait { !model.busy && model.displayRows.contains { $0.dayKey == "2026-09-22" && $0.moment != nil } }
        if let today = model.displayRows.first(where: { $0.dayKey == "2026-09-22" && $0.moment != nil }), let tm = today.moment {
            model.select(today.id)
            model.openMoment()
            check(browser.focusedDay == nil && browser.selectedMomentID == tm.id && browser.expandedMomentID == tm.id,
                  "Show in Context on today's moment stays on today with it selected")
        } else {
            check(false, "a moment from today is found")
        }

        // The existing legacy search adapter applies app/site filters to the original hits before moment resolution.
        browser.searchCanonicalQuery = nil
        browser.searchCanonical = { _, _ in found }
        browser.query = "launch"
        model.applyFilter(RecallFilter(kind: .site, value: "x.com", label: "X"))
        check(wait { !model.busy && model.displayRows.count == 2 && model.displayRows.allSatisfy { $0.moment != nil } },
              "a site-filtered search settles with two original moments")
        equal(Set(model.displayRows.map(\.id)), Set(xRows.map(\.id)),
              "filtering preserves original child moment identity instead of creating a session wrapper")
        check(!model.displayRows.isEmpty && model.displayRows.allSatisfy { $0.hits.allSatisfy { URL(string: $0.evidence.url)?.host == "x.com" } },
              "every retained filtered hit belongs to the requested site")
        model.applyFilter(RecallFilter(kind: .app, value: zed.1, label: zed.0))
        check(wait { !model.busy && model.displayRows.count == 2 && model.displayRows.allSatisfy { $0.moment?.bundles == [zed.1] } },
              "an app-filtered search excludes nearby moments from other apps")
        if let past = model.displayRows.first(where: { $0.dayKey == "2026-09-21" }), let pm = past.moment {
            model.select(past.id); model.openMoment()
            check(browser.focusedDay == pm.dayKey && browser.selectedMomentID == pm.id && browser.expandedMomentID == pm.id
                  && browser.reference?.moments == [pm.id], "filtered result returns to its own day and child selection")
            let before = browser.contextRevealSerial
            browser.showInDay(pm)
            check(browser.contextRevealSerial == before + 1 && browser.selectedMomentID == pm.id,
                  "the timeline detail uses the same route and repeated context requests preserve selection")
        } else { check(false, "filtered search retains its matching past-day moment") }
        browser.query = ""; browser.recallPresented = false
    }

    // MARK: - Source

    static func source(_ path: String) -> String {
        (try? String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)) ?? ""
    }
    /// The code without its `//` comment lines, whitespace squeezed to single spaces.
    static func squeezed(_ s: String) -> String {
        s.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
            .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    static func sourceChecks() {
        equal(ShowInContextButton.title, "Show in Context", "the button reads exactly Show in Context")
        let kit = squeezed(source("Sources/MemoryUI/DaydreamKitMoments.swift"))
        let detail = squeezed(source("Sources/MemoryUI/RecallDetail.swift"))
        let preview = squeezed(source("Sources/MemoryUI/RecallPreview.swift"))
        let model = squeezed(source("Sources/MemoryUI/RecallModel.swift"))
        let browser = squeezed(source("Sources/MemoryUI/ActivityModel.swift"))
        let timeline = squeezed(source("Sources/MemoryUI/CanonicalTimeline.swift"))
        let focusDetail = squeezed(source("Sources/MemoryUI/FocusListDetail.swift"))
        let rows = squeezed(source("Sources/MemoryUI/RecallRows.swift"))
        let expanded = squeezed(source("Sources/MemoryUI/FocusListExpanded.swift"))
        let panel = squeezed(source("Sources/MemoryUI/RecallPanel.swift"))
        let commands = squeezed(source("Sources/MacMemApp/AppCommands.swift"))
        check(commands.contains("if c.canFindRelated { Button(\"Find Related Moments\") { browser.send(.findRelated) } .keyboardShortcut(\"r\", modifiers: .command) .disabled(!selected) }"),
              "the global menu creates neither Find Related nor its shortcut when detail/search refuses that action")
        check(!kit.isEmpty && !detail.isEmpty && !preview.isEmpty && !model.isEmpty && !rows.isEmpty, "sources read (run from the repo root)")
        check(kit.contains("if let onShowInContext { VStack(alignment: .leading, spacing: 10) { summary ShowInContextButton(action: onShowInContext) } }"),
              "the moment detail draws Show in Context directly under the summary")
        check(!detail.contains("RecallDetailView") && !detail.contains("MomentDetailBody") && !panel.contains("RecallDetail")
              && !model.contains("detailRowID") && model.contains("public func openMoment() { guard selectedRow != nil else { return } if menuOpen { closeMenu() } showInDay() }"),
              "search has no pushed detail: Return and a double-click run Show in Context")
        check(preview.contains("summary(m) ShowInContextButton { model.showInDay() }"), "search's preview draws Show in Context under the summary")
        check(model.contains("case .showInToday: showInDay()"), "Show in Today (⌘T, the menus) runs the same showInDay")
        check(model.contains("browser.showInDay(m)") && browser.contains("focusedDay = moment.dayKey == today ? nil : moment.dayKey")
              && browser.contains("selectedMomentID = moment.id expandedMomentID = moment.id"),
              "showInDay opens the row's own day with its moment selected and open")
        check(kit.contains("Text(Self.title).font(.system(size: 12, weight: .medium)) .frame(height: 30) } .buttonStyle(FocusLinkButtonStyle())")
              && expanded.contains(".font(.system(size: 12, weight: .medium)) .frame(height: 30) } .buttonStyle(FocusLinkButtonStyle())"),
              "shared Show in Context exactly matches the existing Show All font, height and link style")
        check(kit.contains("MomentSummaryAndHistory {") && kit.contains("OwnerSourceMomentProjection.history(actions")
              && model.contains("actionRow.map(menuItems(for:)) ?? []"),
              "summary and chronological history remain separate alongside existing Copy/Forget presentation")
        check(!focusDetail.contains("onShowInContext:") && !expanded.contains("ShowInContextButton"),
              "Show in Context is offered only by search, never timeline detail or expanded cards")
        check(timeline.contains(".onChange(of: browser.contextRevealSerial) { _ in popDetail() if let id = browser.expandedMomentID ?? browser.selectedMomentID { box.reveal(id, animated: false) } writeContext() }")
              && timeline.components(separatedBy: "context: detailID == nil ? .focusList : .focusListDetail").count == 3,
              "timeline detail menu and shortcut rules change together and context navigation pops the old detail and requeues the original child even with unchanged ids")
        for (name, text) in [("RecallModel", model), ("RecallRows", rows), ("RecallPreview", preview), ("RecallDetail", detail)] {
            check(!text.contains("FocusListLayout") && !text.contains("TimelineSession"),
                  "\(name) builds search rows without the timeline's blocks or sessions")
        }
        check(!model.contains("Find Related Moments\", symbol"), "Recall adds no Find Related Moments item of its own")
        check(!(detail + preview).contains("Find Related"), "the search detail and preview name no Find Related")
    }
}
