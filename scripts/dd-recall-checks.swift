// DD-RECIPE: UI
//
// A2 Recall (find-A) checks (plan §5 A2, amendments A2). Recall hosted offscreen inside the real
// MemoryShell (and alone, for the list-only size) over a temp MemoryStore under DD_CHECK_OUT, with
// `searchCanonicalQuery` answering real store results re-encoded as the backend/status/paging each
// case needs. Keys go through the window to the recall field's editor, as typing does.
//  - A query alone presents the panel; bounds 900×620 (split) and 680×480 (list only), light and dark.
//  - Rendered item ids equal the result's items in order; Best match only with Typesense and ≥ 1 item;
//    the empty result shows the empty state (its title alone, never the raw `coverage` text).
//  - `next` paging (⌥↩) appends without duplicate ids.
//  - Detail return: row 7 → Return → Esc keeps the selection and the list scroll (≤ 2 pt); Esc again
//    closes (recallPresented false, query cleared). ↑/↓ and the ^/v buttons step results in the detail
//    while the field keeps first responder; ⌃↑/⌃↓ alias them.
//  - Actions menu keyboard contract: the field stays first responder; with the menu open ↑/↓, Return,
//    typing and Backspace go to the menu; Esc closes the menu first.
//  - Forget (moment and single action): only the confirm step commits, Cancel releases the preview.
//  - Exclude: absent for an always-private app; excludeApp once, only after the confirm button.
//  - Open Original: reopenCanonical once, for the selected result only; a failed reopen disables it
//    until the query changes.
//  - Opening, typing and closing Recall call no recording action. commandContext follows Recall.
//  - Source lint of the Recall files: vocabulary, retired strings, macOS 13 SF Symbols, no key equivalents.
// SwiftUI's accessibility tree is not available to an offscreen check (dd-kit logs the same LIMIT), so
// the drawn copy is read from the model properties the views draw, the panel frame from the panel's own
// measurement, the list scroll from its real NSScrollView, and buttons are pressed with mouse events.
// Synthetic data only: no app, no permissions, no recording, no general pasteboard writes.
import AppKit
import SwiftUI
import Combine
import MemoryCore
import MemoryUI

/// Reports itself key, so the field editor and SwiftUI behave as in the app while offscreen.
final class RecallKeyWindow: NSWindow {
    /// Stays offscreen (a titled window is otherwise moved onto a screen).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    override var isKeyWindow: Bool { true }
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

/// Counts every `CaptureActions` closure call. Recall must make none.
@MainActor final class RecallCalls {
    var total = 0
    var actions: CaptureActions {
        var a = CaptureActions(pause: { [unowned self] _ in self.total += 1 }, resume: { [unowned self] in self.total += 1 },
                               stop: { [unowned self] in self.total += 1 }, settings: { [unowned self] in self.total += 1 })
        a.openSystemSettings = { [unowned self] _ in self.total += 1 }
        a.checkPermissions = { [unowned self] in self.total += 1 }
        a.openSettingsSection = { [unowned self] _ in self.total += 1 }
        a.openMain = { [unowned self] in self.total += 1 }
        a.openRecall = { [unowned self] in self.total += 1 }
        a.quit = { [unowned self] in self.total += 1 }
        return a
    }
}

/// What the browser's closures saw.
@MainActor final class RecallRecorder {
    var queries: [MemorySearchQuery] = []
    var respond: (MemorySearchQuery) throws -> MemorySearchResult = { _ in throw MemError.missing }
    var reopened: [String] = []
    var reopenFails = false
    var openedApps: [String] = []
    var previews: [MemoryActionScope] = []
    var confirmed: [String] = []
    var cancelled: [String] = []
    var excluded: [String] = []
    var excludeError: Error?
}

@main @MainActor enum DDRecallChecks {
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
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("claude-dd-recall-\(getpid())", isDirectory: true)
        return base.appendingPathComponent("stores", isDirectory: true)
    }()

    static func main() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
            FileHandle.standardError.write(Data("FAIL: dd-recall watchdog expired\n".utf8)); exit(2)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.removeItem(at: root)
        sourceLint()
        do {
            try seed()
            presentsAndBounds()
            resultsAndSections()
            paging()
            nothingFoundYet()
            detailReturn()
            detailStepping()
            presentedTypingAndClose()
            actionsMenuKeys()
            openOriginal()
            forget()
            exclude()
            reviewRound()
            listOnly()
            legacyFilterField()
            check(calls.total == 0, "opening, typing, stepping and closing Recall called no recording action", "\(calls.total) calls")
        } catch {
            check(false, "check setup", "\(error)")
        }
        window.orderOut(nil)
        try? FileManager.default.removeItem(at: root)
        if failures > 0 {
            FileHandle.standardError.write(Data("FAIL: \(failures) dd-recall check(s) failed\n".utf8)); exit(1)
        }
        print("PASS dd-recall-checks: Recall panel, keys, actions and copy; synthetic temp store only, no recording")
        exit(0)
    }

    // MARK: - Fixture

    static var store: MemoryStore!
    /// The real SQLite-fallback result for "permission", newest first (32 hits, 16 moments, 3 days).
    static var base: MemorySearchResult!
    static var orphanIDs: Set<String> = []

    static func seed() throws {
        let home = root.appendingPathComponent("recall", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        var n = 0
        func moment(_ day: Int, _ h: Int, _ m: Int, _ app: String, _ bundle: String, _ title: String, url: String = "") throws {
            for k in 0..<2 {
                n += 1
                _ = try store.ingest(Evidence(id: "e\(n)", at: iso(d(day, h, m + 3 * k)), kind: "window.changed", app: app, bundle: bundle,
                                              title: title, url: url, synthetic: true), now: clock)
            }
        }
        let zed = ("Zed", "dev.zed.Zed"), safari = ("Safari", "com.apple.Safari"), notes = ("Notes", "com.apple.Notes")
        let terminal = ("Terminal", "com.apple.Terminal"), textEdit = ("TextEdit", "com.apple.TextEdit"), numbers = ("Numbers", "com.apple.iWork.Numbers")
        try moment(22, 15, 40, zed.0, zed.1, "PermissionSetup.swift permission rows")
        try moment(22, 15, 0, safari.0, safari.1, "Permission prompts pull request", url: "https://github.com/acme/app/pull/12")
        try moment(22, 14, 20, notes.0, notes.1, "Permission copy drafts")
        try moment(22, 13, 40, terminal.0, terminal.1, "permission tests run")
        try moment(22, 13, 0, zed.0, zed.1, "permission banner layout")
        try moment(22, 12, 20, safari.0, safari.1, "Permission docs reading", url: "https://developer.apple.com/documentation/permissions")
        try moment(22, 11, 40, notes.0, notes.1, "permission meeting notes")
        try moment(22, 11, 0, textEdit.0, textEdit.1, "permission wording review")
        try moment(22, 10, 20, numbers.0, numbers.1, "permission budget sheet")
        try moment(22, 9, 40, zed.0, zed.1, "permission model sketch")
        try moment(21, 16, 0, safari.0, safari.1, "Permission prompt wording", url: "https://github.com/acme/app/issues/7")
        try moment(21, 14, 0, notes.0, notes.1, "permission checklist")
        try moment(21, 11, 0, zed.0, zed.1, "permission refactor")
        try moment(21, 9, 0, terminal.0, terminal.1, "permission migration")
        try moment(20, 15, 0, textEdit.0, textEdit.1, "permission letter")
        try moment(20, 10, 0, numbers.0, numbers.1, "permission costs")
        var found = try store.searchResult(MemorySearchQuery("permission", start: d(19, 0, 0), limit: 50), now: clock)
        found.items.sort { (timestamp($0.evidence.at) ?? .distantPast) > (timestamp($1.evidence.at) ?? .distantPast) }
        found.next = nil
        base = found
        equal(found.items.count, 32, "fixture: 32 hits for \"permission\" across 16 moments")
        let today = try store.dayLayers(day: "2026-09-22", timezone: zone, limit: 200, now: clock)
        equal(today.activities.count, 10, "fixture: ten moments today")
        check(found.items.contains { !$0.evidence.url.isEmpty }, "fixture: web hits keep their page address")
    }

    static func result(_ items: [MemoryItem], backend: String = "sqlite", status: String = "ready", partial: Bool = false, next: String? = nil) -> MemorySearchResult {
        var r = base!
        r.items = items; r.backend = backend; r.status = status; r.partial = partial; r.next = next
        return r
    }
    /// A hit the store does not hold (it stays an action row): Zed, 1Password, or a web page.
    static func orphan(_ id: String, app: String, bundle: String, title: String, url: String = "", at: Date) -> MemoryItem {
        var item = base.items[0]
        item.id = id
        item.evidence = Evidence(id: id, at: iso(at), kind: "window.changed", app: app, bundle: bundle, title: title, url: url, synthetic: true)
        item.summary = "Edited " + title
        orphanIDs.insert(id)
        return item
    }

    static let recorder = RecallRecorder()
    static let calls = RecallCalls()

    static func makeBrowser() -> ActivityBrowser {
        let b = ActivityBrowser(calendar: cal)
        let rec = recorder, source = store!
        b.now = { clock }
        b.summaries = SummaryAvailability(provider: .local, busy: false)
        b.exclusions = ExclusionSummary(alwaysPrivate: ["com.1password.1password"], excludedByYou: [])
        b.loadCanonicalDay = { day, cursor in try source.dayLayers(day: day, timezone: zone, after: cursor, limit: 200, now: clock) }
        b.searchCanonicalQuery = { q in rec.queries.append(q); return try rec.respond(q) }
        b.reopenCanonical = { id in rec.reopened.append(id); if rec.reopenFails { throw MemError.missing } }
        b.openApp = { rec.openedApps.append($0) }
        b.excludeApp = { rec.excluded.append($0); if let e = rec.excludeError { throw e } }
        b.generateCanonicalNote = { _, _, _, _ in }
        b.previewCanonicalDelete = { scope in
            rec.previews.append(scope)
            let object: [String: Any] = ["id": "preview-" + (scope.id ?? "?"),
                                         "scope": ["kind": scope.kind, "id": scope.id ?? "", "day": scope.day ?? "", "timezone": scope.timezone ?? ""],
                                         "actionIDs": [], "actionCount": scope.kind == "action" ? 1 : 2, "revision": "r",
                                         "expiresAt": "2099-01-01T00:00:00Z", "warning": ""]
            return try JSONDecoder().decode(DeletionPreview.self, from: JSONSerialization.data(withJSONObject: object))
        }
        b.confirmCanonicalDelete = { rec.confirmed.append($0) }
        b.cancelCanonicalDelete = { rec.cancelled.append($0) }
        return b
    }

    // MARK: - Hosting

    static let window: RecallKeyWindow = {
        let w = RecallKeyWindow(contentRect: NSRect(x: -4000, y: -4000, width: 1172, height: 792), styleMask: [.titled, .resizable],
                                backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.orderFrontRegardless()
        return w
    }()
    static var browser: ActivityBrowser!
    static var model: RecallModel { browser.recallModel }

    static func pump(_ s: Double = 0.1) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
    @discardableResult
    static func wait(_ seconds: Double = 6, _ condition: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { return false }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
        return true
    }

    static func hostShell(_ b: ActivityBrowser, size: NSSize = NSSize(width: 1172, height: 792)) {
        browser = b
        let state = CapturePresentation(state: .recording(since: d(22, 8, 40)))
        let root = MemoryShell(browser: b, state: state, actions: calls.actions)
            .environment(\.daydreamNow, clock).environment(\.daydreamStatic, true)
        window.setContentSize(size)
        let host = NSHostingView(rootView: AnyView(root))
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        pump(0.3)
    }

    static func views(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(views) }
    static var field: NSTextField? {
        window.contentView.flatMap { views($0).first { $0.identifier?.rawValue == "recall-field" } as? NSTextField }
    }
    /// The field's editor is the window's first responder (typing and keys go to Recall).
    static var fieldFocused: Bool {
        guard let f = field, let editor = window.firstResponder as? NSTextView else { return false }
        return (editor.delegate as AnyObject?) === f
    }

    /// A point in the hosting view (top-left origin, SwiftUI's global space) → a click there.
    static func click(_ p: CGPoint) {
        guard let host = window.contentView else { return }
        let wp = host.convert(NSPoint(x: p.x, y: p.y), to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            if let e = NSEvent.mouseEvent(with: type, location: wp, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                          windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                                          pressure: type == .leftMouseDown ? 1 : 0) {
                window.sendEvent(e)
            }
        }
        pump(0.15)
    }
    /// The panel in the hosting view's space (SwiftUI's global space starts at the window's top, above the title bar).
    static var panelInHost: CGRect {
        let inset = window.frame.height - (window.contentView?.frame.height ?? window.frame.height)
        return model.panelFrame.offsetBy(dx: 0, dy: -inset)
    }
    /// The results list's scroll view: the NSScrollView at the panel's left edge, 440 pt wide (or the panel's width).
    static var listScroll: NSScrollView? {
        guard let host = window.contentView else { return nil }
        let panel = panelInHost
        let width = model.split ? 440 : panel.width
        return views(host).compactMap { $0 as? NSScrollView }.first { sv in
            let r = sv.convert(sv.bounds, to: host)
            return abs(r.minX - panel.minX) <= 2 && abs(r.width - width) <= 2 && r.minY > panel.minY && r.maxY <= panel.maxY + 1
        }
    }
    static var listOffset: CGFloat? { listScroll?.documentVisibleRect.minY }

    // Keys, delivered like the window server does: to the window, then its first responder.
    static let upKey = String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!), downKey = String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!)
    static func key(_ code: UInt16, _ chars: String, _ flags: NSEvent.ModifierFlags = []) {
        guard let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                       windowNumber: window.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars,
                                       isARepeat: false, keyCode: code) else { return }
        window.sendEvent(e)
        pump(0.06)
    }
    static func up(_ flags: NSEvent.ModifierFlags = []) { key(126, upKey, NSEvent.ModifierFlags([.numericPad, .function]).union(flags)) }
    static func down(_ flags: NSEvent.ModifierFlags = []) { key(125, downKey, NSEvent.ModifierFlags([.numericPad, .function]).union(flags)) }
    static func returnKey(_ flags: NSEvent.ModifierFlags = []) { key(36, "\r", flags) }
    static func escape() { key(53, "\u{1b}") }
    static func backspace() { key(51, "\u{7f}") }
    static func type(_ text: String) { for ch in text { key(0, String(ch)) } }

    /// The search settled and every hit the store holds sits in its moment.
    @discardableResult
    static func settled(_ what: String) -> Bool {
        let ok = wait(8) {
            !model.busy && model.result != nil && model.searchedText == model.queryText
                && model.displayRows.allSatisfy { $0.moment != nil || $0.itemIDs.allSatisfy(orphanIDs.contains) }
        }
        pump(0.25)
        if !ok { check(false, "\(what): the search settles", "busy \(model.busy) rows \(model.displayRows.count)") }
        return ok
    }
    static func search(_ respond: @escaping (MemorySearchQuery) throws -> MemorySearchResult) {
        recorder.respond = respond
        model.retry()
        pump(0.05)
    }

    // MARK: - Presenting, bounds

    static func presentsAndBounds() {
        recorder.respond = { _ in result(base.items) }
        hostShell(makeBrowser())
        check(field == nil && model.panelFrame == .zero, "no query, not presented: Recall is not mounted")
        browser.query = "sample"
        check(wait { field != nil } && browser.recallPresented == false, "query = \"sample\" alone presents the panel (recallPresented stays false)")
        wait { fieldFocused }
        check(fieldFocused, "the recall field takes first responder when the panel appears")
        equal(field?.placeholderAttributedString?.string, "Search your notes and what you've seen", "placeholder copy (N2)")
        // The toolbar's trigger shows the same line, and as it narrows cuts at a phrase boundary, never mid-word.
        equal(ToolbarSearchTrigger.placeholderSteps, ["Search your notes and what you've seen", "Search what you've seen", "Search"],
              "toolbar placeholder: whole, then shorter at phrase boundaries")
        equal(field?.font?.pointSize, 22, "the field is 22 pt")
        browser.query = "permission"
        settled("presented by query")
        equal(recorder.queries.last?.limit, 50, "Recall searches through searchCanonicalQuery with limit 50")
        check(recorder.queries.last?.start != nil, "the date range (Past 30 Days) reaches MemorySearchQuery.start")
        if let start = recorder.queries.last?.start { equal(Int(clock.timeIntervalSince(start) / 86_400), 30, "Past 30 Days starts 30 days back") }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            pump(0.3)
            let tag = appearance == .aqua ? "light" : "dark"
            equal(model.panelSize, CGSize(width: 900, height: 620), "\(tag): panel bounds are 900×620 in a 1172×792 window")
            check(model.split, "\(tag): 900 wide shows the list and the preview")
            let frame = model.panelFrame, bounds = window.contentView?.bounds ?? .zero
            check(abs(frame.width - 900) <= 1 && abs(frame.height - 620) <= 1, "\(tag): the panel is drawn 900×620", "\(frame)")
            check(bounds.contains(panelInHost) && abs(frame.midX - bounds.midX) <= 1, "\(tag): the panel is centred and inside the window", "\(panelInHost) in \(bounds)")
            if let list = listScroll, let host = window.contentView {
                equal(list.convert(list.bounds, to: host).minY - panelInHost.minY, 61, "\(tag): the list starts under the 60 pt query bar and its rule")
            }
        }
        window.appearance = nil
        print("LIMIT: SwiftUI accessibility children unavailable offscreen; VoiceOver labels read from the model the rows draw")
        let ctx = browser.commandContext
        check(ctx.recallVisible && ctx.hasSelection, "Recall writes commandContext while visible (recallVisible, hasSelection)", "\(ctx)")
    }

    // MARK: - Results, Best match, empty

    static func resultsAndSections() {
        // SQLite fallback: newest first, no Best match.
        search { _ in result(base.items) }
        settled("sqlite")
        let ids = base.items.map(\.id)
        equal(model.renderedItemIDs, ids, "rendered item ids equal the searchCanonicalQuery items, in order")
        equal(Set(model.renderedItemIDs).count, model.renderedItemIDs.count, "no item is rendered twice")
        equal(model.displayRows.count, 16, "32 hits group into 16 moment rows")
        check(!model.bestMatchShown && !model.sectionTitles.contains("Best match"), "no Best match without Typesense", "\(model.sectionTitles)")
        equal(Array(model.sectionTitles.prefix(2)), ["Today", "Yesterday"], "day groups newest first")
        // ux/declutter: the title names the day; no trailing date repeats it, only another year's number.
        check(model.sections.allSatisfy { $0.detail == nil }, "day groups: no trailing date beside the title", "\(model.sections.map(\.detail))")
        equal(RecallModel.sectionDetail(d(22, 10, 0), now: d(22, 12, 0), calendar: cal), nil, "day groups: this year's day has no trailing text")
        equal(RecallModel.sectionDetail(d(22, 10, 0).addingTimeInterval(-400 * 86_400), now: d(22, 12, 0), calendar: cal), "2025",
              "day groups: a day in another year shows its year")
        let first = model.displayRows[0]
        let label = model.voiceOverLabel(first)
        check(label.hasPrefix(first.title + ", Zed, Today 3:40") && label.hasSuffix("PM"), "a row reads \"{title}, {app}, {day} {time}\" to VoiceOver", label)

        // Typesense: relevance order, the first hit is the Best match.
        var ranked = base.items
        ranked.insert(ranked.remove(at: 24), at: 0)   // a hit from yesterday ranks first
        search { _ in result(ranked, backend: "typesense") }
        settled("typesense")
        check(model.bestMatchShown && model.sectionTitles.first == "Best match", "Typesense with results: Best match first", "\(model.sectionTitles)")
        check(model.displayRows.first?.itemIDs.contains(ranked[0].id) == true, "the Best match row holds the first-ranked hit")
        equal(model.sections.first?.rows.count, 1, "Best match is one row")
        equal(Set(model.renderedItemIDs), Set(ranked.map(\.id)), "Typesense: every hit rendered")
        equal(model.renderedItemIDs.count, ranked.count, "Typesense: no hit rendered twice")
        equal(model.sections.filter(\.best).flatMap(\.rows).count, 1, "exactly one row is the Best match (its VoiceOver value)")

        // Typesense, nothing found: the empty state and no Best match.
        search { _ in result([], backend: "typesense") }
        settled("empty")
        check(model.showsNoResults && !model.bestMatchShown && model.sectionTitles.isEmpty, "an empty result shows the empty state, no Best match",
              "\(model.sectionTitles)")
        equal(model.emptyTitle, "No moments match \u{201C}permission\u{201D}", "empty state title")
        // ux/declutter: the empty state is its title alone; the footer says where it searched.
        // ux/declutter: one privacy line everywhere ("Searched on this Mac" and "On this Mac" were two wordings of it).
        equal(model.footerText, "On this Mac", "empty state: the footer says On this Mac")
        check(!source("Sources/MemoryUI/RecallRows.swift").contains("emptyDetail"), "empty state: no coverage line under the title")
        let shown = [model.emptyTitle, model.footerText, model.statusLine ?? ""]
        check(!shown.contains { $0.contains(base.coverage) || $0.contains("Canonical metadata") }, "the raw coverage text is never displayed")

        // Catching up: the status line; an error: the error state.
        search { _ in result(Array(base.items.prefix(6)), backend: "typesense", status: "catching_up", partial: true) }
        settled("catching up")
        equal(model.statusLine, RecallModel.catchingUpText, "catching_up shows the index line")
        equal(RecallModel.catchingUpText, "Some recent moments may not show yet.", "the index line in plain words")
        recorder.respond = { _ in throw MemError.database("down") }
        model.retry()
        wait { model.error != nil && !model.busy }
        pump(0.2)
        equal(model.error, "Search unavailable.", "a failed search shows Search unavailable. (the Try Again button follows)")
        recorder.respond = { _ in result(base.items) }
        model.retry()
        settled("retry")
        equal(model.renderedItemIDs, ids, "Try Again searches again")
    }

    // MARK: - Paging

    static func paging() {
        let page1 = Array(base.items.prefix(20)), page2 = Array(base.items[18..<32])   // two ids overlap
        search { q in q.after == "page-2" ? result(page2, partial: false) : result(page1, partial: true, next: "page-2") }
        settled("page 1")
        equal(model.items.count, 20, "page 1: 20 items")
        equal(model.statusLine, nil, "a result with next adds no status line (Search More History says it)")
        check(model.hasMore, "Search More History is offered")
        let before = recorder.queries.count
        returnKey(.option)
        wait { !model.busy && model.items.count > 20 }
        pump(0.2)
        equal(recorder.queries.count, before + 1, "⌥↩ asks for exactly one more page")
        equal(recorder.queries.last?.after, "page-2", "the next page carries the cursor")
        equal(recorder.queries.last?.limit, 50, "the next page keeps limit 50")
        equal(model.items.map(\.id), base.items.map(\.id), "next paging appends the new items once (overlap dropped)")
        equal(Set(model.renderedItemIDs).count, model.renderedItemIDs.count, "paging renders no duplicate ids")
        equal(model.renderedItemIDs.count, 32, "all 32 hits rendered after paging")
        returnKey(.option)
        pump(0.3)
        equal(recorder.queries.count, before + 1, "⌥↩ without next asks for nothing")
    }

    // MARK: - Detail return

    // MARK: - Nothing found yet (gold/connections-storage, G27 review)

    /// A page with nothing on it while more history is left: Recall asks for the next pages by itself (the cursor
    /// carried, the same search) and shows what a later page found, with no Search More History click. When nothing
    /// turns up in the time it gives itself, the title says how far back it looked, never that nothing matches.
    static func nothingFoundYet() {
        let hit = base.items[0]
        func empty(_ next: String?, back: Date?) -> MemorySearchResult {
            var r = result([], partial: next != nil, next: next); r.scannedBackTo = back.map(iso); return r
        }
        var before = recorder.queries.count
        search { q in
            switch q.after {
            case nil: return empty("page-2", back: d(21, 15, 42))
            case "page-2": return empty("page-3", back: d(20, 9, 5))
            default: return result([hit], partial: false)
            }
        }
        settled("nothing on the first two pages")
        let asked = Array(recorder.queries[before...])
        equal(asked.map(\.after), [nil, "page-2", "page-3"], "an empty page with more history left: Recall asks for the next pages by itself")
        check(asked.allSatisfy { $0.limit == 50 && $0.text == asked.first?.text && $0.start == asked.first?.start },
              "…the same search each time (limit 50, the same words and range)")
        equal(model.items.map(\.id), [hit.id], "…and shows what a later page found, with no Search More History click")
        check(!model.hasMore && !model.showsNoResults, "…as the whole answer")
        // Nothing within the time Recall gives itself: say how far back it looked; Search More History goes on.
        let saved = RecallModel.autoContinueSeconds
        RecallModel.autoContinueSeconds = 0.3
        before = recorder.queries.count
        search { q in empty("more-\(q.after ?? "")", back: d(21, 15, 42)) }
        settled("nothing found for a while")
        RecallModel.autoContinueSeconds = saved
        check(recorder.queries.count - before > 1, "nothing found for a while: Recall kept asking by itself", "\(recorder.queries.count - before) searches")
        check(model.showsNoResults && model.hasMore, "…then shows the empty state with Search More History")
        equal(model.emptyTitle, "Nothing found back to yesterday 3:42 PM", "…whose title says how far back it looked")
        check(!model.emptyTitle.contains("No moments match"), "…never that nothing matches while more history is left")
        RecallModel.autoContinueSeconds = 0
        search { _ in empty("more", back: nil) }
        settled("nothing found, no time known")
        RecallModel.autoContinueSeconds = saved
        equal(model.emptyTitle, "Nothing found yet", "more history left and no time to name: \"Nothing found yet\"")
        // The whole range searched, nothing found: the final words stay.
        search { _ in result([]) }
        settled("nothing anywhere")
        equal(model.emptyTitle, "No moments match \u{201C}\(model.searchedText)\u{201D}", "the whole range searched: No moments match")
    }

    static func detailReturn() {
        search { _ in result(base.items) }
        settled("detail")
        check(fieldFocused, "the field has first responder before stepping")
        for _ in 0..<15 { down() }
        equal(model.selectedIndex, 15, "↓ walks to the last row")
        for _ in 0..<9 { up() }
        equal(model.selectedIndex, 6, "↑ comes back to row 7")
        pump(0.3)
        let seven = model.selectedRow
        let top = listOffset
        check(listScroll != nil, "harness: the results list's scroll view is found")
        check((top ?? 0) > 40, "harness: walking to the end and back leaves the list scrolled", "\(String(describing: top))")
        // claude/searchui-1005 (owner 10/04): no pushed detail. The selection stays put; Return is Show in Context.
        equal(model.selectedRowID, seven?.id, "row 7 stays selected")
        check(browser.recallVisible, "walking the results keeps the panel")
    }

    /// claude/searchui-1005 (owner 10/04: the full-page result repeated the preview): Return shows the selected result
    /// in context (its own day, the moment selected and open) and closes search; nothing is pushed.
    static func detailStepping() {
        let rows = model.displayRows
        model.select(rows[6].id)
        let m = rows[6].moment
        equal(model.menuItems.first { $0.id == .openMoment }?.title, nil, "no Open Moment item (Show in <Day> is the one)")
        returnKey()
        pump(0.3)
        check(!browser.recallVisible && browser.query.isEmpty && !browser.recallPresented, "Return shows the result in context and closes search")
        if let m { check(browser.selectedMomentID == m.id && browser.expandedMomentID == m.id, "Return opens row 7's moment in its day") }
        browser.focusedDay = nil; browser.selectedMomentID = nil; browser.expandedMomentID = nil; browser.reference = nil
        check(wait { field == nil }, "the panel is gone")
        equal(browser.commandContext, DaydreamCommandContext(), "closing Recall resets commandContext")
    }

    // MARK: - Presented, typing, close

    static func presentedTypingAndClose() {
        browser.recallPresented = true
        check(wait { field != nil && fieldFocused }, "recallPresented opens the panel with the field focused")
        wait { !model.displayRows.isEmpty }
        pump(0.2)
        equal(model.sectionTitles, ["Recent"], "the empty query shows Recent")
        equal(model.displayRows.count, 3, "the last three moments of today")
        check(model.renderedItemIDs.isEmpty, "no search result is shown for the empty query")
        let searchesBefore = recorder.queries.count
        type("permission")
        equal(browser.query, "permission", "typing in the field sets the query")
        settled("typed")
        equal(recorder.queries.count, searchesBefore + 1, "typing ten characters searches once (debounced)")
        // Esc order (spec §find-A keys): close menu → back from detail → clear query → close panel.
        escape()
        check(browser.recallVisible && browser.recallPresented && browser.query.isEmpty, "Esc from the results clears the query; a summoned panel stays open")
        wait { !model.displayRows.isEmpty }
        equal(model.sectionTitles, ["Recent"], "after clearing, the panel shows Recent")
        check(fieldFocused, "the field keeps first responder after the query is cleared")
        escape()
        check(!browser.recallVisible && !browser.recallPresented && browser.query.isEmpty, "Esc again closes a presented panel")
        check(wait { field == nil }, "the panel unmounts")
    }

    // MARK: - Actions menu keyboard contract

    static func actionsMenuKeys() {
        browser.query = "permission"
        wait { field != nil }
        search { _ in result(base.items) }
        settled("menu")
        wait { fieldFocused }
        let selected = model.selectedRowID
        browser.send(.toggleActions)
        pump(0.2)
        check(model.menuOpen, "⌘K (toggleActions) opens the Actions menu")
        check(fieldFocused, "the field keeps first responder while the menu is open")
        let firstItem = model.menuSelection
        check(firstItem != nil, "the menu highlights its first item")
        down()
        check(model.menuSelection != firstItem && model.selectedRowID == selected, "↓ moves the menu highlight, not the result selection",
              "\(String(describing: model.menuSelection))")
        up()
        equal(model.menuSelection, firstItem, "↑ moves the menu highlight back")
        type("sho")
        equal(model.menuFilter, "sho", "typing goes to the menu's type-select")
        equal(browser.query, "permission", "typing with the menu open leaves the query alone")
        equal(model.menuSelection, .showInToday, "typing highlights Show in <Day>")
        check(!model.menuItems.contains { $0.id == .findRelated }, "search's Actions menu has no Find Related Moments (owner, 9/30)")
        equal(model.visibleMenuItems.count, model.menuItems.count, "typing hides no menu item (the menu has no search line)")
        backspace()
        equal(model.menuFilter, "sh", "Backspace edits what was typed")
        equal(browser.query, "permission", "Backspace with the menu open leaves the query alone")
        escape()
        check(!model.menuOpen && browser.recallVisible, "Esc closes the menu first; the panel stays")
        equal(model.selectedRowID, selected, "closing the menu keeps the selection")
        let shown = model.selectedRow
        browser.send(.toggleActions)
        type("sho")
        returnKey()
        pump(0.2)
        check(!model.menuOpen && !browser.recallVisible,
              "Return runs the highlighted item (Show in <Day> closes search), and does not open the moment")
        if let m = shown?.moment {
            check(browser.selectedMomentID == m.id && browser.expandedMomentID == m.id, "Show in <Day> keeps the moment selected and open")
        }
        browser.focusedDay = nil; browser.selectedMomentID = nil; browser.expandedMomentID = nil; browser.reference = nil
        browser.query = "permission"
        wait { field != nil && fieldFocused }
        settled("menu again")
        check(fieldFocused, "the field has first responder when search opens again")
        // The timeline's Find Related Moments scopes search to an app or site (`.daydreamRecallFilter`).
        model.applyFilter(RecallFilter(kind: .app, value: "com.apple.Safari", label: "Safari"))
        settled("related")
        let q = recorder.queries.last
        check(q?.app != nil || q?.site != nil, "the filter reaches MemorySearchQuery (app or site)", "\(String(describing: q?.app)) \(String(describing: q?.site))")
        check(model.filter?.chipTitle.map { $0.hasPrefix("In ") || $0.hasPrefix("From ") } == true, "the filter chip reads In <App> or From <site>",
              "\(String(describing: model.filter?.chipTitle))")
        model.applyFilter(nil)
        settled("unfiltered")
    }

    // MARK: - Open Original

    static func openOriginal() {
        guard let web = model.displayRows.first(where: { row in row.hits.contains { !$0.evidence.url.isEmpty } }),
              let hit = web.hits.first(where: { !$0.evidence.url.isEmpty }) else { check(false, "a web result exists"); return }
        let other = model.displayRows.first { $0.id != web.id }
        model.select(web.id)
        pump(0.2)
        recorder.reopened = []
        browser.send(.openOriginal)
        wait(2) { !recorder.reopened.isEmpty }
        pump(0.2)
        equal(recorder.reopened, [hit.id], "Open Original reopens the selected result's page once")
        check(other.map { row in !row.itemIDs.contains { recorder.reopened.contains($0) } } ?? true, "no other result is reopened")
        browser.send(.toggleActions)
        type("original")
        returnKey()
        wait(2) { recorder.reopened.count == 2 }
        equal(recorder.reopened, [hit.id, hit.id], "the Actions menu's Open Original reopens the same page once more")
        recorder.reopenFails = true
        browser.send(.openOriginal)
        wait(2) { recorder.reopened.count == 3 }
        pump(0.3)
        check(model.originalBlocked, "a failed reopen shows the original-unavailable banner")
        browser.send(.openOriginal)
        pump(0.3)
        equal(recorder.reopened.count, 3, "⌘↩ is disabled after a failed reopen")
        check(!browser.commandContext.canOpenOriginal, "commandContext disables Open Original after a failed reopen")
        recorder.reopenFails = false
        browser.query = "permission "
        pump(0.1)
        browser.query = "permission"
        settled("after reopen failure")
        model.select(web.id)
        browser.send(.openOriginal)
        wait(2) { recorder.reopened.count == 4 }
        equal(recorder.reopened.count, 4, "changing the query enables Open Original again")
    }

    // MARK: - Forget

    static func sheet() -> (texts: [String], buttons: [NSButton])? {
        guard let s = window.attachedSheet, let cv = s.contentView else { return nil }
        let all = views(cv)
        return (all.compactMap { ($0 as? NSTextField)?.stringValue }.filter { !$0.isEmpty }, all.compactMap { $0 as? NSButton })
    }
    static func click(_ title: String) -> Bool {
        guard let b = sheet()?.buttons.first(where: { $0.title == title }) else { return false }
        b.performClick(nil); pump(0.4)
        return true
    }

    static func forget() {
        wait(4) { !model.busy && model.displayRows.contains { $0.moment != nil } }
        guard let row = model.displayRows.first(where: { $0.moment != nil }) else {
            check(false, "a moment row exists", "busy \(model.busy) rows \(model.displayRows.count) query \(model.queryText)"); return
        }
        model.select(row.id)
        recorder.previews = []; recorder.confirmed = []; recorder.cancelled = []
        browser.send(.forget)
        check(wait(3) { sheet() != nil }, "Forget asks first")
        check(sheet()?.texts.contains("Forget this moment?") == true, "the moment alert asks Forget this moment?", "\(sheet()?.texts ?? [])")
        check(recorder.previews.count == 1 && recorder.confirmed.isEmpty, "asking prepares one preview and commits nothing")
        check(click("Cancel"), "the alert has Cancel")
        check(recorder.confirmed.isEmpty && recorder.cancelled == ["preview-" + (recorder.previews.first?.id ?? "")], "Cancel releases the preview and deletes nothing",
              "confirmed \(recorder.confirmed) cancelled \(recorder.cancelled)")
        browser.send(.forget)
        check(wait(3) { sheet() != nil }, "Forget asks again")
        check(click("Forget"), "the alert has Forget")
        equal(recorder.confirmed.count, 1, "only the confirm step calls confirmCanonicalDelete, once")
        equal(recorder.previews.first?.kind, "activity", "a moment is forgotten with an activity scope")
        equal(recorder.previews.first?.id, row.moment?.id, "the scope is the selected moment")
        settled("after forget")

        // An ungrouped hit forgets one action.
        let zed = orphan("orphan-zed", app: "Zed", bundle: "dev.zed.Zed", title: "scratch.swift", at: d(22, 16, 10))
        let pass = orphan("orphan-1p", app: "1Password", bundle: "com.1password.1password", title: "Vault", at: d(22, 16, 5))
        search { _ in result([zed, pass] + base.items) }
        settled("orphans")
        check(model.displayRows.contains { $0.id == "action:orphan-zed" && $0.moment == nil && $0.title == "Action in Zed" },
              "a hit outside any moment is an action row titled Action in Zed")
        model.select("action:orphan-zed")
        recorder.previews = []; recorder.confirmed = []; recorder.cancelled = []
        browser.send(.forget)
        check(wait(3) { sheet() != nil } && sheet()?.texts.contains("Forget this action?") == true, "an action row asks Forget this action?",
              "\(sheet()?.texts ?? [])")
        check(click("Cancel") && recorder.confirmed.isEmpty && recorder.cancelled == ["preview-orphan-zed"], "action forget: Cancel releases the preview")
        browser.send(.forget)
        wait(3) { sheet() != nil }
        check(click("Forget") && recorder.confirmed == ["preview-orphan-zed"], "action forget: only Forget commits", "\(recorder.confirmed)")
        equal(recorder.previews.first?.kind, "action", "an action row is forgotten with an action scope")
        settled("after action forget")
    }

    // MARK: - Exclude

    static func exclude() {
        let zed = orphan("orphan-zed", app: "Zed", bundle: "dev.zed.Zed", title: "scratch.swift", at: d(22, 16, 10))
        let pass = orphan("orphan-1p", app: "1Password", bundle: "com.1password.1password", title: "Vault", at: d(22, 16, 5))
        search { _ in result([zed, pass] + base.items) }
        settled("exclude")
        model.select("action:orphan-1p")
        pump(0.1)
        check(!model.menuItems.contains { $0.id == .exclude }, "Exclude is absent for 1Password (always private)",
              "\(model.menuItems.map(\.title))")
        check(browser.commandContext.excludeAppName == nil, "commandContext offers no exclusion for 1Password")
        browser.send(.exclude)
        pump(0.4)
        check(sheet() == nil && recorder.excluded.isEmpty, "the Exclude command does nothing for 1Password")
        if let pw = model.displayRows.first(where: { $0.moment?.primaryBundle == "com.apple.Safari" }) {
            model.select(pw.id)
            check(model.menuItems.contains { $0.id == .exclude && $0.title == "Exclude Safari from Recording…" }, "a moment offers Exclude <App> from Recording…",
                  "\(model.menuItems.map(\.title))")
        }
        model.select("action:orphan-zed")
        recorder.excluded = []
        browser.send(.exclude)
        check(wait(3) { sheet() != nil } && sheet()?.texts.contains("Exclude Zed from recording?") == true, "Exclude asks first", "\(sheet()?.texts ?? [])")
        check(recorder.excluded.isEmpty, "asking excludes nothing")
        check(click("Cancel") && recorder.excluded.isEmpty, "Cancel excludes nothing")
        browser.send(.exclude)
        wait(3) { sheet() != nil }
        check(click("Exclude"), "the sheet has Exclude")
        wait(2) { !recorder.excluded.isEmpty }
        equal(recorder.excluded, ["dev.zed.Zed"], "excludeApp is called once, only after the confirm button")
        settled("after exclude")
        model.close()
        check(wait { field == nil } && !browser.recallVisible, "close() closes Recall")
    }

    // MARK: - Review round (A2 design review)

    static func reviewRound() {
        ribbonSegments()
        browser.query = "permission"
        check(wait { field != nil }, "review: a query presents the panel again")
        wait { fieldFocused }

        // VoiceOver hears the list's count once the hits sit in their moments, never the raw hit count.
        search { _ in result(Array(base.items.prefix(1))) }
        settled("one hit")
        wait(3) { model.lastAnnouncement == "1 result" }
        equal(model.lastAnnouncement, "1 result", "VoiceOver hears 1 result")
        var heard = Set<String>()
        search { _ in result(base.items) }
        let grouped = wait(6) {
            if let a = model.lastAnnouncement { heard.insert(a) }
            return model.lastAnnouncement == "16 results"
        }
        check(grouped, "VoiceOver hears the grouped count (16 results)", "\(heard)")
        check(!heard.contains("32 results"), "VoiceOver never hears the ungrouped hit count", "\(heard)")

        // Rows in a day read newest first by the time they show, whatever order the backend ranks them in.
        // A hit at 9:42 goes above the moment that starts at 9:40, though that moment's newest hit is 9:43.
        let reversed = Array(base.items.reversed())
        let between = orphan("orphan-942", app: "Zed", bundle: "dev.zed.Zed", title: "permission probe", at: d(22, 9, 42))
        search { _ in result(reversed + [between], backend: "typesense") }
        settled("reversed ranking")
        let days = model.sections.filter { !$0.best }
        check(!days.isEmpty && days.allSatisfy { s in zip(s.rows, s.rows.dropFirst()).allSatisfy { $0.time >= $1.time } },
              "rows within a day are newest first by the time they show",
              days.map { $0.rows.map { DaydreamFormat.time($0.time, la) }.joined(separator: " ") }.joined(separator: " | "))
        let today = days.first?.rows.map(\.id) ?? []
        if let hit = today.firstIndex(of: "action:orphan-942"), let sketch = model.displayRows.first(where: { $0.title.contains("model sketch") }),
           let moment = today.firstIndex(of: sketch.id) {
            check(hit < moment, "a 9:42 hit sits above the moment shown at 9:40 (whose newest hit is 9:43)", "\(today)")
        } else { check(false, "the 9:42 hit and the 9:40 moment are both listed today", "\(today)") }

        // Best match skips the core's last-ten-seconds rows, which it lists ahead of the ranked hits.
        let fresh = orphan("orphan-fresh", app: "Zed", bundle: "dev.zed.Zed", title: "permission scratch", at: clock.addingTimeInterval(-5))
        search { _ in result([fresh] + reversed, backend: "typesense") }
        settled("fresh hit")
        let best = model.sections.first
        check(best?.best == true && best?.rows.first?.itemIDs.contains(reversed[0].id) == true
              && best?.rows.first?.itemIDs.contains("orphan-fresh") == false,
              "Best match skips a hit from the last ten seconds and holds the first ranked hit", "\(best?.rows.first?.itemIDs ?? [])")
        check(model.renderedItemIDs.contains("orphan-fresh"), "the recent hit is still listed")

        // An index that is catching up never claims the whole range, with results or without.
        for (status, partial) in [("catching_up", true), ("stale_hits_removed", false)] {
            search { _ in result([], backend: "typesense", status: status, partial: partial) }
            settled("empty \(status)")
            check(model.showsNoResults, "\(status), nothing found: the empty state")
            equal(model.statusLine, RecallModel.catchingUpText, "\(status), nothing found: the index line shows")
            check(!model.footerText.contains("30 days") && !model.emptyTitle.contains("30 days"), "\(status), nothing found: nothing claims a date range")
        }

        // A site filter on a www page: the filter keeps the raw host the core compares; the chip drops www.
        let apple = orphan("orphan-www", app: "Safari", bundle: "com.apple.Safari", title: "Newsroom permission story",
                           url: "https://www.apple.com/newsroom/", at: d(22, 16, 12))
        search { _ in result([apple] + base.items) }
        settled("www page")
        model.select("action:orphan-www")
        check(!model.menuItems.contains { $0.id == .findRelated }, "a single hit's Actions menu has no Find Related Moments")
        model.applyFilter(RecallFilter(kind: .site, value: "www.apple.com", label: "apple.com"))
        settled("www related")
        equal(recorder.queries.last?.site, "www.apple.com", "a www.apple.com filter scopes the search to www.apple.com")
        equal(model.filter?.chipTitle, "From apple.com", "the chip reads From apple.com")
        model.applyFilter(nil)
        settled("www unfiltered")

        // Typed text is not indexed, so it is never an Action match reason (the summary can carry it).
        var typed = orphan("orphan-typed", app: "Notes", bundle: "com.apple.Notes", title: "Reply draft", at: d(22, 16, 14))
        typed.evidence = Evidence(id: "orphan-typed", at: iso(d(22, 16, 14)), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes",
                                  title: "Reply draft", text: "the permission follow-up", synthetic: true)
        typed.summary = "Typed \u{201C}the permission follow-up\u{201D} in Reply draft in Notes."
        search { _ in result([typed] + base.items) }
        settled("typed text")
        if let row = model.displayRows.first(where: { $0.id == "action:orphan-typed" }) {
            check(!model.matchSources(row).contains(.action), "typed text is never an Action match reason", "\(model.matchSources(row))")
        } else { check(false, "the typed-text hit is an action row") }
        if let row = model.displayRows.first(where: { $0.moment != nil }) {
            equal(model.matchSources(row), [.window], "a title match is listed once, as Window title (not again as Action)")
        }

        // Open names where it goes; Edit Correction is not offered from Recall.
        search { _ in result(base.items) }
        settled("menu titles")
        if let zed = model.displayRows.first(where: { $0.moment?.primaryBundle == "dev.zed.Zed" }) {
            model.select(zed.id)
            pump(0.1)
            let open = model.menuItems.first { $0.id == .openOriginal || $0.id == .openApp }
            equal(open?.title, "Open Zed", "an app target is Open Zed in the Actions menu")
            equal(browser.commandContext.openTitle, "Open Zed", "the ⌘↩ menu item reads Open Zed")
            check(!model.menuItems.contains { $0.id == .editCorrection }, "Edit Correction is not in Recall's Actions menu", "\(model.menuItems.map(\.title))")
            check(!browser.commandContext.canEditCorrection, "commandContext: Edit Correction is off while Recall acts")
        } else { check(false, "a Zed moment row exists") }
        if let web = model.displayRows.first(where: { row in row.hits.contains { !$0.evidence.url.isEmpty } }) {
            model.select(web.id)
            pump(0.1)
            equal(model.menuItems.first { $0.id == .openOriginal || $0.id == .openApp }?.title, "Open Original", "a verified web original is Open Original")
            equal(browser.commandContext.openTitle, "Open Original", "the ⌘↩ menu item reads Open Original")
        }

        // The date-range menu: ↑/↓ move its highlight, Return picks, Esc closes it first.
        let selected = model.selectedRowID
        model.toggleRangeMenu()
        check(model.rangeMenuOpen && model.rangeHighlight == .month, "the date-range chip opens its menu on the current range")
        check(fieldFocused, "the field keeps first responder with the range menu open")
        down()
        equal(model.rangeHighlight, .all, "↓ moves the range highlight")
        equal(model.selectedRowID, selected, "↓ with the range menu open leaves the result selection alone")
        up(); up()
        equal(model.rangeHighlight, .week, "↑ moves the range highlight back")
        escape()
        check(!model.rangeMenuOpen && browser.recallVisible && model.period == .month && browser.query == "permission",
              "Esc closes the range menu first; the range, the query and the panel stay")
        model.toggleRangeMenu()
        up()
        let asked = recorder.queries.count
        returnKey()
        check(!model.rangeMenuOpen && model.period == .week && browser.recallVisible, "Return picks the highlighted range (and opens no moment)")
        settled("past 7 days")
        check(recorder.queries.count > asked, "picking a range searches again")
        if let start = recorder.queries.last?.start { equal(Int(clock.timeIntervalSince(start) / 86_400), 7, "Past 7 Days reaches MemorySearchQuery.start") }
        model.setPeriod(.month)
        settled("past 30 days")

        // A failed exclusion shows the app's own text; nothing claims the app was or wasn't excluded.
        let zedHit = orphan("orphan-zed", app: "Zed", bundle: "dev.zed.Zed", title: "scratch.swift", at: d(22, 16, 10))
        search { _ in result([zedHit] + base.items) }
        settled("exclude failure")
        model.select("action:orphan-zed")
        recorder.excluded = []
        recorder.excludeError = MemError.invalid("Not saved. Recording is stopped. Retry.")
        browser.send(.exclude)
        check(wait(3) { sheet() != nil } && click("Exclude"), "the exclusion is confirmed in the sheet")
        check(wait(2) { model.notice != nil }, "a failed exclusion leaves a notice")
        check(model.notice?.contains("Recording is stopped") == true && model.notice?.contains("Nothing changed") != true,
              "the notice is the app's own text, never Nothing changed", model.notice ?? "nil")
        equal(recorder.excluded, ["dev.zed.Zed"], "excludeApp was asked once")
        equal(RecallModel.excludeFailureText(MemError.missing), "The exclusion wasn't confirmed. Review exclusions in Settings.",
              "any other failure makes no claim about what changed")
        recorder.excludeError = nil

        // Esc with a filter and no query clears the filter before closing a summoned panel.
        model.close()
        check(wait { field == nil }, "close() closes Recall")
        browser.recallPresented = true
        check(wait { field != nil && fieldFocused }, "Recall summoned again")
        model.applyFilter(RecallFilter(kind: .site, value: "github.com", label: "github.com"))
        settled("filter only")
        escape()
        check(model.filter == nil && browser.recallPresented && browser.recallVisible, "Esc clears the filter first; the summoned panel stays")
        escape()
        check(!browser.recallPresented && !browser.recallVisible, "Esc again closes it")
        check(wait { field == nil }, "the panel unmounts")

        // Find Related from the Focus List reaches only its own window's Recall.
        let other = makeBrowser(), otherModel = other.recallModel
        let site = RecallFilter(kind: .site, value: "github.com", label: "github.com")
        NotificationCenter.default.post(name: .daydreamRecallFilter, object: other, userInfo: site.userInfo)
        check(wait(2) { otherModel.filter == site }, "a filter posted for another window's browser reaches that window's Recall")
        check(model.filter == nil, "and is not applied here")
        NotificationCenter.default.post(name: .daydreamRecallFilter, object: browser, userInfo: site.userInfo)
        check(wait(2) { model.filter == site }, "a filter posted for this browser is applied here")
        model.applyFilter(nil)
        otherModel.applyFilter(nil)
        model.close()
        pump(0.3)
    }

    static func member(_ id: String, _ at: Date, app: String, bundle: String) -> CanonicalAction {
        let object: [String: Any] = ["id": id, "evidenceIDs": [id], "at": iso(at), "kind": "window.changed", "app": app, "bundle": bundle, "site": "",
                                     "title": "t", "description": "d", "state": "active", "revision": "r", "subject": "s", "observationKey": id]
        return try! JSONDecoder().decode(CanonicalAction.self, from: JSONSerialization.data(withJSONObject: object))
    }

    /// ux/declutter: the preview is the moment's header and summary; its Activity strip, ticks, app list and
    /// "Why it matched" lines are gone (the detail's What happened lists the actions).
    static func ribbonSegments() {
        let preview = source("Sources/MemoryUI/RecallPreview.swift")
        for gone in ["RecallActivity", "RecallAxis", "DDRibbon(", "recallMatches", "recallAppCounts"] {
            check(!preview.contains(gone), "preview: draws no \(gone)")
        }
    }

    // MARK: - Legacy filter field (placement is contract request 2)

    static func legacyFilterField() {
        let b = ActivityBrowser(calendar: cal)
        let host = NSHostingView(rootView: AnyView(RecallLegacyFilterField(browser: b).frame(width: 400).padding(10)))
        let size = NSSize(width: 420, height: 64)
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        pump(0.3)
        guard let tf = views(host).compactMap({ $0 as? NSTextField }).first(where: \.isEditable) else {
            check(false, "the legacy filter hosts an editable field"); window.contentView = nil; return
        }
        equal(tf.placeholderString ?? tf.placeholderAttributedString?.string, "Filter this list", "legacy filter placeholder")
        window.makeFirstResponder(tf)
        pump(0.1)
        type("sensor")
        equal(b.query, "sensor", "typing in the legacy filter writes browser.query")
        b.query = ""
        pump(0.2)
        equal(tf.stringValue, "", "clearing browser.query clears the legacy filter")
        window.contentView = nil
    }

    // MARK: - List only (680×480)

    static func listOnly() {
        let b = makeBrowser()
        browser = b
        recorder.respond = { _ in result(base.items) }
        let host = NSHostingView(rootView: AnyView(RecallHost(browser: b, state: CapturePresentation(state: .recording(since: d(22, 8, 40))), actions: calls.actions)
            .environment(\.daydreamNow, clock).environment(\.daydreamStatic, true)))
        let size = NSSize(width: 720, height: 520)
        window.setContentSize(size)
        host.frame = NSRect(origin: .zero, size: size)
        window.contentView = host
        b.query = "permission"
        pump(0.3)
        settled("list only")
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            pump(0.3)
            let tag = appearance == .aqua ? "light" : "dark"
            equal(model.panelSize, CGSize(width: 680, height: 480), "\(tag): panel bounds are 680×480 in a 720×520 area")
            check(!model.split, "\(tag): below 760 wide the list stands alone")
            let frame = model.panelFrame
            check(abs(frame.width - 680) <= 1 && abs(frame.height - 480) <= 1, "\(tag): the panel is drawn 680×480", "\(frame)")
            check(listScroll != nil, "\(tag): the list spans the panel's width")
        }
        window.appearance = nil
        equal(model.renderedItemIDs, base.items.map(\.id), "list only renders the same items in order")
        window.contentView = nil
    }

    // MARK: - Source lint (Recall files)

    static let recallFiles = ["RecallHost.swift", "RecallModel.swift", "RecallPanel.swift", "RecallRows.swift", "RecallPreview.swift",
                              "RecallDetail.swift", "RecallSearchField.swift"]
    /// Built from pieces so repository greps for these words never match this file.
    static let banned: [String] = {
        let remember = "Remem", cap = "cap" + "ture"
        return [remember + "bering", "remem" + "bering", "Start remem" + "bering", "Pause " + cap, "Resume " + cap, "Stop " + cap,
                "Never " + remember + "ber", "Tomor" + "row", "Mac" + " Mem", "URL" + "Session", "Day" + "dream", "Stored on" + " this Mac",
                "Summarized on" + " this Mac"]
    }()

    static func literals(_ line: String) -> [String] {
        var out: [String] = [], current = ""
        var inQuote = false, escape = false, depth = 0, nested = false
        var prev: Character = " "
        for ch in line {
            if depth > 0 {
                if nested { if ch == "\"" { nested = false } }
                else if ch == "\"" { nested = true }
                else if ch == "(" { depth += 1 }
                else if ch == ")" { depth -= 1 }
            } else if inQuote {
                if escape {
                    escape = false
                    if ch == "(" { depth = 1; current.append("\u{FFFC}") } else { current.append(ch) }
                } else if ch == "\\" { escape = true }
                else if ch == "\"" { inQuote = false; out.append(current); current = "" }
                else { current.append(ch) }
            } else {
                if ch == "/" && prev == "/" { break }
                if ch == "\"" { inQuote = true }
            }
            prev = ch
        }
        return out
    }
    static let symbolMacOS: [String: String]? = {
        let url = URL(fileURLWithPath: "/System/Library/CoreServices/CoreGlyphs.bundle/Contents/Resources/name_availability.plist")
        guard let plist = NSDictionary(contentsOf: url), let symbols = plist["symbols"] as? [String: String],
              let years = plist["year_to_release"] as? [String: [String: String]] else { return nil }
        var out: [String: String] = [:]
        for (name, year) in symbols { if let mac = years[year]?["macOS"] { out[name] = mac } }
        return out
    }()
    static func version(_ v: String) -> [Int] { v.split(separator: ".").map { Int($0) ?? 0 } + [0, 0, 0] }

    static func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    static func sourceLint() {
        equal(RecallMatchSource.allCases.map(\.label), ["Window title", "Page", "App", "Action"], "match sources: Window title, Page, App, Action")
        equal(RecallMatchSource.allCases.map(\.short), ["Window", "Page", "App", "Action"], "short source labels: Window, Page, App, Action")
        check(!RecallMatchSource.allCases.contains { ["Typed", "Summary"].contains($0.short) || $0.label.contains("Typed") }, "no Typed or Summary source")
        if symbolMacOS == nil { print("LIMIT: CoreGlyphs availability table unreadable; symbols checked for existence only") }
        for file in recallFiles {
            guard let text = try? String(contentsOfFile: "Sources/MemoryUI/" + file, encoding: .utf8) else { check(false, "\(file) is readable"); continue }
            let code = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            let lits = code.flatMap(literals)
            var hits: [String] = []
            for word in banned where lits.contains(where: { $0.contains(word) }) { hits.append(word) }
            if lits.contains(where: { $0.lowercased().contains("cap" + "ture") }) { hits.append("cap" + "ture") }
            if lits.contains(where: { $0.range(of: #"(?<![0-9] )remember"#, options: [.regularExpression, .caseInsensitive]) != nil }) { hits.append("remember") }
            check(hits.isEmpty, "\(file): literals keep the Recording vocabulary and retired strings out", "\(hits)")
            check(!code.contains { $0.contains(".keyboardShortcut(") }, "\(file): installs no key equivalents (menus and the field own the keys)")
            check(!code.contains { $0.contains(".onKeyPress") || $0.contains("focusEffectDisabled") || $0.contains("scrollPosition(id") }, "\(file): no macOS 14 view APIs")
            var late: [String] = []
            for lit in lits where lit.range(of: #"^[a-z][a-z0-9]*(\.[a-z0-9]+)*$"#, options: .regularExpression) != nil
                && NSImage(systemSymbolName: lit, accessibilityDescription: nil) != nil {
                if let table = symbolMacOS, let mac = table[lit], !version(mac).lexicographicallyPrecedes(version("13.0.1")) { late.append(lit) }
            }
            check(late.isEmpty, "\(file): every SF Symbol draws on macOS 13.0", "\(Set(late).sorted())")
        }
        // Esc with focus off the field (Full Keyboard Access, Tab onto a row or a button) takes the same step back
        // as Esc in the field and hands the keys back to it. onExitCommand does not fire for synthesized events
        // offscreen, so its wiring is pinned in the source; the step itself is RecallModel.cancel(), driven above.
        let panel = (try? String(contentsOfFile: "Sources/MemoryUI/RecallPanel.swift", encoding: .utf8)) ?? ""
        check(panel.contains(".onExitCommand { model.cancel(); model.requestFocus() }"),
              "Esc off the field: the panel's onExitCommand calls model.cancel() and returns focus to the field")
        print("LIMIT: onExitCommand is not delivered to an offscreen host; the Esc-off-the-field path is pinned in RecallPanel.swift")
        let deleted = FileManager.default.fileExists(atPath: "Sources/MemoryUI/CanonicalSearch.swift")
        check(!deleted, "CanonicalSearch.swift is removed")
    }
}
