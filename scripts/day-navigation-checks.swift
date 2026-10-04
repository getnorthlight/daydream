import Foundation
@testable import MemoryCore
@testable import MemoryUI

/// Day navigation, day titles and the toolbar's keyboard focus (owner 10/2). Model-level only: a synthetic temp store,
/// pure functions and source pins. No app, window, view hosting, capture or owner data.
@main @MainActor enum DayNavigationChecks {
    static var checks = 0
    static func require(_ ok: Bool, _ reason: String, _ got: @autoclosure () -> String = "") {
        guard ok else { FileHandle.standardError.write(Data("FAIL: \(reason) \(got())\n".utf8)); exit(1) }
        checks += 1
    }
    static let zone = "America/Chicago"
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }
    static func d(_ month: Int, _ day: Int, _ h: Int = 12, _ m: Int = 0, year: Int = 2026) -> Date {
        cal.date(from: DateComponents(year: year, month: month, day: day, hour: h, minute: m))!
    }
    static func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

    static func main() async throws {
        stepRule()
        try recordedDaysFromStore()
        await stepperTargets()
        emptyDayAndWeekLine()
        titles()
        toolbarFocus()
        print("PASS: day-navigation \(checks) checks; synthetic temp store only, no windows")
    }

    /// Previous/Next Day skip days with nothing (owner 10/2: Back from Today landed on an empty day).
    static func stepRule() {
        let recorded = ["2026-09-22", "2026-10-01", "2026-10-02"]
        let today = "2026-10-02"
        func step(_ key: String, _ dir: Int, _ rec: [String]? = recorded) -> String? {
            FocusDay.step(from: key, by: dir, today: today, recorded: rec, calendar: cal)
        }
        require(step(today, -1) == "2026-10-01", "back from today is yesterday when yesterday has records")
        require(step("2026-10-01", -1) == "2026-09-22", "back skips the empty days in between", step("2026-10-01", -1) ?? "nil")
        require(step("2026-09-22", -1) == nil, "nothing before the first recorded day: Previous has nowhere to go")
        require(step("2026-09-22", 1) == "2026-10-01", "forward skips empty days too")
        require(step("2026-10-01", 1) == today, "forward reaches today")
        require(step(today, 1) == nil, "no next day on today")
        require(step("2026-09-30", -1) == "2026-09-22" && step("2026-09-30", 1) == "2026-10-01",
                "an empty day reached by the calendar steps to its recorded neighbours")
        require(step(today, -1, ["2026-10-02"]) == nil, "only today recorded: no previous day")
        require(step(today, -1, []) == nil, "nothing recorded at all: no previous day")
        require(step("2026-09-28", 1, ["2026-09-01"]) == today, "forward past the last recorded day is today, even if today is empty")
        require(step(today, -1, nil) == "2026-10-01" && step("2026-10-01", 1, nil) == today,
                "unknown recorded days: one calendar day, as before")
        require(step("2026-10-01", 0) == nil, "no direction, no step")
    }

    /// The store names the local days that hold records, from their hours only.
    static func recordedDaysFromStore() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("claude-day-nav-\(getpid())", isDirectory: true)
        try? FileManager.default.removeItem(at: home)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        let clock = d(10, 2, 18)
        func ev(_ id: String, _ at: Date) -> Evidence {
            Evidence(id: id, at: iso(at), kind: "window.changed", app: "TextEdit", bundle: "com.apple.TextEdit", title: "Fictional notes", synthetic: true)
        }
        // Sep 22 afternoon, Oct 1 late evening (after 7 PM local = next day in UTC), Oct 2 just after midnight local.
        for (i, at) in [d(9, 22, 15, 26), d(9, 22, 15, 40), d(10, 1, 22, 20), d(10, 2, 0, 13), d(10, 2, 17, 0)].enumerated() {
            _ = try store.ingest(ev("e\(i)", at), now: clock)
        }
        let days = try MemoryStore(home: home).recordedDays(timezone: zone)
        require(days == ["2026-09-22", "2026-10-01", "2026-10-02"], "recorded days are local days, oldest first, none empty", "\(days)")
        let utc = try MemoryStore(home: home).recordedDays(timezone: "UTC")
        require(utc == ["2026-09-22", "2026-10-02"], "the same records in UTC fall on UTC days", "\(utc)")
        var threw = false
        do { _ = try MemoryStore(home: home).recordedDays(timezone: "Not/AZone") } catch { threw = true }
        require(threw, "an unknown time zone is refused")
    }

    /// The toolbar stepper and Go menu read the cache's recorded days.
    static func stepperTargets() async {
        let browser = ActivityBrowser(calendar: cal)
        browser.now = { d(10, 2, 18) }
        browser.loadCanonicalDay = { _, _ in throw MemError.missing }
        _ = browser.dayCache.syncTodayKey()
        require(browser.dayCache.todayKey == "2026-10-02", "fixture today")
        require(DayStepper.target(browser, direction: -1) == "2026-10-01", "before the read: one calendar day back")
        browser.loadRecordedDays = { _ in ["2026-09-22", "2026-10-02"] }
        browser.dayCache.loadRecordedDays()
        let end = Date().addingTimeInterval(5)
        while browser.dayCache.recordedDays == nil, Date() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
        require(browser.dayCache.recordedDays == ["2026-09-22", "2026-10-02"], "the cache holds the recorded days")
        require(DayStepper.target(browser, direction: -1) == "2026-09-22", "Previous Day from Today goes to the last recorded day")
        browser.focusedDay = "2026-09-22"
        require(DayStepper.target(browser, direction: -1) == nil, "Previous Day is disabled on the first recorded day")
        require(DayStepper.target(browser, direction: 1) == "2026-10-02", "Next Day from it is Today")
        let timeline = source("Sources/MemoryUI/CanonicalTimeline.swift")
        require(timeline.contains("FocusDay.step(from: dayKey, by: direction, today: todayKey, recorded: cache.recordedDays, calendar: calendar)"),
                "the page's ⌘[ ⌘] and stepper commands use the same rule")
        require(timeline.contains("cache.loadRecordedDays()"), "the page reads the recorded days when it appears")
        let menu = source("Sources/MacMemApp/AppCommands.swift")
        require(menu.contains("DayStepper.target(browser, direction: -1) == nil"), "Go ▸ Previous Day is disabled by the same rule")
        let app = source("Sources/MacMemApp/MacMemApp.swift")
        require(app.contains("activity.loadRecordedDays = {") && app.contains(".recordedDays(timezone:zone)"), "the app wires the store read")
    }

    /// A day with nothing shows the empty card, never a card holding only the week line; no day card draws a week line.
    static func emptyDayAndWeekLine() {
        var snap = TodaySnapshot(dayKey: "2026-09-30", loadedAt: d(10, 2), momentCount: 0, actionCount: 0, countComplete: true, partial: false,
                                 moments: [], headline: nil, headlineBullets: [], headlineGeneratedAt: nil, headlineLocal: nil,
                                 firstObserved: nil, lastObserved: nil, topApps: [], latest: nil,
                                 summaries: SummaryAvailability(provider: .local, busy: false), readyCount: 0, pendingCount: 0,
                                 tooLongCount: 0, appCount: 0)
        snap.levels = DayLevelSlice(dayTitle: nil, dayLines: [], blocks: [], weekLabel: "Week of Sep 28 to Oct 4", weekTitle: "Asked ChatGPT about Claude")
        require(FocusListLayout.showsEmptyCard(snap, isToday: false), "a past day with only a week note shows the empty card (no week-only card)")
        snap.levels = DayLevelSlice(dayTitle: "Mostly the pricing page", dayLines: [], blocks: [], weekLabel: "Week of Sep 28 to Oct 4", weekTitle: "x")
        require(!FocusListLayout.showsEmptyCard(snap, isToday: false), "a past day with a kept day note still shows its card")
        let card = source("Sources/MemoryUI/FocusListSummaryCard.swift")
        require(!card.contains("weekLine") && !card.contains("weekLabel"), "the day card draws no week line")
    }

    /// One date form: "Today", else "Thu, Oct 1" in the header; Recall's groups say Today, Yesterday, else "Wed, Sep 30".
    static func titles() {
        let now = d(10, 2, 17)
        require(DaydreamFormat.dayHeader(d(10, 2, 9), now: now, calendar: cal) == "Today", "header: today")
        require(DaydreamFormat.dayHeader(d(10, 1), now: now, calendar: cal) == "Thu, Oct 1", "header: yesterday as its date")
        require(DaydreamFormat.dayHeader(d(9, 30), now: now, calendar: cal) == "Wed, Sep 30", "header: this week")
        require(DaydreamFormat.dayHeader(d(9, 22), now: now, calendar: cal) == "Tue, Sep 22", "header: older, no year line")
        require(DaydreamFormat.dayHeader(d(12, 29, year: 2025), now: now, calendar: cal) == "Mon, Dec 29, 2025", "header: another year names it")
        // Late evening stays on its own local day.
        require(DaydreamFormat.dayHeader(d(10, 1, 23, 59), now: now, calendar: cal) == "Thu, Oct 1", "header: 11:59 PM is still that day")
        require(DaydreamFormat.dayTitle(d(10, 1), now: now, calendar: cal).title == "Yesterday", "recall title: yesterday")
        let older = DaydreamFormat.dayTitle(d(9, 28), now: now, calendar: cal)
        require(older.title == "Mon, Sep 28" && older.date == "Monday, September 28", "recall title: weekday and date, one form", "\(older)")
        let far = DaydreamFormat.dayTitle(d(9, 14), now: now, calendar: cal)
        require(far.title == "Mon, Sep 14", "recall title: older than a week keeps the same form (no bare \"Sep 14\")", far.title)
        let tz = TimeZone(identifier: zone)!
        require(DaydreamFormat.range(d(10, 1, 17, 14), d(10, 1, 17, 22), tz) == "5:14\u{2013}5:22 PM", "bracket range: 5:14–5:22 PM")
        require(DaydreamFormat.range(d(10, 1, 11, 40), d(10, 1, 12, 10), tz) == "11:40 AM\u{2013}12:10 PM", "bracket range across noon")
        let header = source("Sources/MemoryUI/FocusListHeader.swift")
        require(header.contains("DaydreamFormat.dayHeader(day, now: now, calendar: calendar)") && !header.contains("dateText("),
                "the header draws one title, never a second date line")
        require(source("Sources/MemoryUI/CanonicalTimeline.swift").contains("backTitle: DaydreamFormat.dayHeader("),
                "the detail's back button names the day as the header does")
    }

    /// Toolbar buttons never keep keyboard focus; Space never presses one.
    static func toolbarFocus() {
        let toolbar = source("Sources/MemoryUI/DaydreamToolbar.swift")
        let uses = toolbar.components(separatedBy: ".toolbarButtonNoFocus()").count - 1
        require(uses >= 3, "stepper segments, search trigger and gear take no focus", "\(uses)")
        require(toolbar.contains("func toolbarButtonNoFocus() -> some View { focusable(false) }"), "no focus means focusable(false)")
        let router = source("Sources/MemoryUI/DaydreamKeyRouter.swift")
        require(router.contains("if self.swallowsToolbarSpace(event) { return true }"), "Space on a toolbar control is dropped before routing")
        require(router.contains("event.keyCode == 49"), "the guard is for Space")
        require(router.contains("window.isKeyWindow"), "routing stays key-window only")
    }
}
