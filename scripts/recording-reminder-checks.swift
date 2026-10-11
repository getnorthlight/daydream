// DD-RECIPE: APP
// rel-019: the recording-off reminder (Sources/MacMemApp/RecordingReminder.swift, RecordingReminderPanel.swift; owner
// 10/10: their own DayDream sat with recording off for a day and a half unnoticed). The pure rules first, then the REAL
// MemoryViewModel with the check seams (in-memory typing keys, no event tap, no login item, fake lock and console reads, a
// fake reminder system with its own clock, idle read, defaults and panel; run-checks.sh sets a synthetic HOME and
// CFFIXED_USER_HOME). Nothing records for real and no window, notification or permission read is used.
//   A. One hour of active use with recording off shows it; 59 minutes don't.
//   B. Idle minutes (input idle over 3 minutes), a locked screen, another user on screen and sleep don't count; the time
//      across a sleep or lock never counts, and a late reading counts at most 5 minutes. rel-019 final: readings 5
//      minutes apart (a timer App Nap throttles) count fully while the person is present at each and nothing came
//      between; a long gap is still capped.
//   C. At most once per calendar day, across a relaunch too; a new day starts the hour over.
//   D. No reminder while setup is unfinished, during a timed pause before it ends, while a permission is missing, while
//      Input Monitoring waits for DayDream to reopen or a change didn't save (rel-019 final: Start would open setup
//      there), or while recording is on; each starts the hour over.
//   E. Start Recording is the menu bar's Start Recording (the panel's `resume`): it records, or with a permission gone
//      opens setup's Permissions page exactly as the menu does; ✕ only hides it. Recording started from anywhere else
//      takes it down.
//   F. Placement: centered under the menu bar item, inside the screen; top right with no item found.
import AppKit
import CSQLite
import MemoryCore
import MemoryUI

@MainActor enum Report {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ id: String, _ message: @autoclosure () -> String) {
        if ok { passed += 1; print("PASS [\(id)] \(message())") } else { failed += 1; print("FAIL [\(id)] \(message())") }
        fflush(stdout)
    }
}
@MainActor func check(_ ok: Bool, _ id: String, _ message: @autoclosure () -> String) { Report.check(ok, id, message()) }
func stop(_ message: String) -> Never { fflush(stdout); FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
@MainActor func tick(_ seconds: Double = 0.05) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
@MainActor func waitFor(_ seconds: Double, _ condition: () -> Bool) async throws -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if condition() { return true }; try await tick(0.05) }
    return condition()
}
func makePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

enum Seams {
    nonisolated(unsafe) static var granted = true
}
/// Defaults kept in memory only (no suite, nothing reaches cfprefsd).
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    init(inMemory: Void = ()) { super.init(suiteName: nil)! }
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) {
        if let value { values[defaultName] = value } else { values.removeValue(forKey: defaultName) }
    }
    override func removeObject(forKey defaultName: String) { values.removeValue(forKey: defaultName) }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { values[defaultName] as? [String: Any] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func bool(forKey defaultName: String) -> Bool { (values[defaultName] as? NSNumber)?.boolValue ?? false }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func double(forKey defaultName: String) -> Double { (values[defaultName] as? NSNumber)?.doubleValue ?? 0 }
    override func set(_ value: Double, forKey defaultName: String) { values[defaultName] = value }
    override func integer(forKey defaultName: String) -> Int { (values[defaultName] as? NSNumber)?.intValue ?? 0 }
    override func set(_ value: Int, forKey defaultName: String) { values[defaultName] = value }
}
@MainActor final class FakeNotices {
    var posted: [RecordingNotice] = []
    var center: RecordingNoticeCenter { RecordingNoticeCenter(prepare: {}, post: { self.posted.append($0) }, clear: {}) }
}
/// Lock and console reads, and the main queue's timers, held until a row runs them.
@MainActor final class FakeWake {
    var locked = false, onConsole = true
    var pending: [(TimeInterval, () -> Void)] = []
    var system: WakeSystem {
        WakeSystem(screenLocked: { self.locked }, onConsole: { self.onConsole },
                   after: { delay, work in self.pending.append((delay, work)) }, now: { Date() })
    }
    func runPending() { let jobs = pending; pending = []; for (_, work) in jobs { work() } }
}
/// The reminder's reads and panel: its own clock (minutes pass only when a row says so), idle read, defaults and a panel
/// that only counts.
@MainActor final class FakeReminder {
    var now: Date
    var idle: TimeInterval = 4
    let defaults: UserDefaults
    var shows = 0, hides = 0
    var start: (() -> Void)?, dismiss: (() -> Void)?
    init(now: Date, defaults: UserDefaults = MemoryDefaults()) { self.now = now; self.defaults = defaults }
    var system: RecordingReminderSystem {
        RecordingReminderSystem(drives: false, idleSeconds: { self.idle }, now: { self.now }, defaults: defaults,
                                show: { start, dismiss in self.shows += 1; self.start = start; self.dismiss = dismiss },
                                hide: { self.hides += 1 })
    }
}
struct Opened { let model: MemoryViewModel; let wake: FakeWake; let reminder: FakeReminder }
/// What a route recorder saw.
@MainActor final class Routes {
    var opened: [String] = [], activations = 0
    var routes: DaydreamMenuBarRoutes { DaydreamMenuBarRoutes(openWindow: { self.opened.append($0) }, activate: { self.activations += 1 }) }
}

@main @MainActor struct RecordingReminderChecks {
    static var out = URL(fileURLWithPath: "/")
    nonisolated static let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Chicago")!; return c }()
    /// 9:00 on a weekday, in the check's calendar.
    nonisolated static func morning(_ day: Int = 12) -> Date { calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 9))! }

    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 240) {
            FileHandle.standardError.write(Data("FAIL: recording-reminder-checks watchdog expired after 240s\n".utf8)); exit(2)
        }
        pureRules()
        placement()

        let env = ProcessInfo.processInfo.environment
        let shared = ["/private/tmp/" + "day" + "dream-", "/tmp/" + "day" + "dream-"]
        guard let outPath = env["DD_CHECK_OUT"], outPath.hasPrefix("/"), !shared.contains(where: { outPath.hasPrefix($0) }) else {
            stop("DD_CHECK_OUT is not a private output directory; run this check through run-checks.sh")
        }
        guard let fixed = env["CFFIXED_USER_HOME"], env["HOME"] == fixed, fixed != "/Users/" + NSUserName(),
              FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path == URL(fileURLWithPath: fixed).standardizedFileURL.path else {
            stop("HOME and CFFIXED_USER_HOME must name one synthetic home; run this check through run-checks.sh")
        }
        out = URL(fileURLWithPath: outPath, isDirectory: true).appendingPathComponent("recording-reminder", isDirectory: true)
        try makePrivateDirectory(out)
        MemoryViewModel.permissionsGranted = { Seams.granted }
        MemoryViewModel.permissionRead = { PermissionSnapshot(accessibility: Seams.granted, inputMonitoring: Seams.granted) }
        MemoryViewModel.startInput = { _ in true }
        MemoryViewModel.readLaunchLocation = { .applications }
        MemoryViewModel.canReopen = { true }
        MemoryViewModel.performAutoRelaunch = { _ in true }
        MemoryViewModel.autoRelaunchDefaults = MemoryDefaults()
        // Setup finished, in the registration domain only (nothing reaches any preferences file).
        UserDefaults.standard.register(defaults: [MemoryViewModel.setupCompletedKey: true])

        try await inertOutsideTheApp()
        try await modelHour()
        try await modelIdleLockSleep()
        try await modelOncePerDay()
        try await modelSetupUnfinished()
        try await modelTimedPause()
        try await modelPermissionMissing()
        try await modelThrottled()
        try await modelReopenNeeded()
        try await modelChangeNotSaved()
        try await startButton()
        try await startButtonPermissionGone()
        try await dismissAndOtherStart()

        print("recording-reminder: \(Report.passed) passed, \(Report.failed) failed")
        fflush(stdout)
        exit(Report.failed == 0 ? 0 : 1)
    }

    // MARK: Pure rules

    /// Readings once a minute from `start`, `count` of them, all alike. Returns the minutes (1-based) at which it showed.
    static func run(_ r: inout RecordingReminder, from start: Date, minutes count: Int, _ reading: RecordingReminder.Reading,
                    first: Int = 0) -> [Int] {
        var shown: [Int] = []
        for m in first..<(first + count) where r.read(reading, now: start.addingTimeInterval(Double(m) * 60), calendar: calendar) { shown.append(m) }
        return shown
    }
    static func pureRules() {
        let t0 = morning(), off = RecordingReminder.Reading(standing: .off)
        // A. The hour: a first reading starts the clock; minute 60 is the hour.
        var a = RecordingReminder()
        check(run(&a, from: t0, minutes: 60, off).isEmpty && a.active == 59 * 60, "A-hour", "59 active minutes with recording off: no reminder (\(a.active) s)")
        check(run(&a, from: t0, minutes: 1, off, first: 60) == [60], "A-hour", "the 60th active minute shows it, once")
        check(a.active == 0 && a.shownDay == "2026-10-12", "A-hour", "…and it counts as shown today: \(String(describing: a.shownDay))")

        // B. Idle, lock, another user, sleep.
        var b = RecordingReminder()
        _ = run(&b, from: t0, minutes: 31, off)
        var idle = off; idle.idle = RecordingReminder.idleLimit + 1
        check(run(&b, from: t0, minutes: 30, idle, first: 31).isEmpty && b.active == 30 * 60, "B-idle", "30 minutes idle over 3 minutes: not counted (\(b.active) s)")
        // The first reading back counts nothing (the minute before it was idle); then idle 3 minutes or less is use.
        var edge = off; edge.idle = RecordingReminder.idleLimit
        check(run(&b, from: t0, minutes: 30, edge, first: 61).isEmpty && b.active == 59 * 60, "B-idle", "input idle 3 minutes or less is use (\(b.active) s)")
        check(run(&b, from: t0, minutes: 1, off, first: 91) == [91], "B-idle", "the hour is active time: the 60th active minute, 91 minutes in, shows it")

        var c = RecordingReminder()
        _ = run(&c, from: t0, minutes: 31, off)
        var locked = off; locked.locked = true
        check(run(&c, from: t0, minutes: 45, locked, first: 31).isEmpty && c.active == 30 * 60, "B-lock", "45 locked minutes: not counted (\(c.active) s)")
        var away = off; away.onConsole = false
        check(run(&c, from: t0, minutes: 20, away, first: 76).isEmpty && c.active == 30 * 60, "B-lock", "20 minutes with another user on screen: not counted (\(c.active) s)")
        var asleep = off; asleep.asleep = true
        check(run(&c, from: t0, minutes: 20, asleep, first: 96).isEmpty && c.active == 30 * 60, "B-sleep", "20 asleep minutes: not counted (\(c.active) s)")
        // The Mac slept 8 hours with no reading at all: the first reading after the wake counts nothing.
        c.interrupted()
        let woke = t0.addingTimeInterval(116 * 60 + 8 * 3600)
        _ = c.read(off, now: woke, calendar: calendar)
        check(c.active == 30 * 60, "B-sleep", "after a sleep the first reading counts nothing (\(c.active) s)")
        // A late reading (the timer held up 10 minutes, no sleep notice) counts at most `longestStep` (5 minutes).
        _ = c.read(off, now: woke.addingTimeInterval(600), calendar: calendar)
        check(RecordingReminder.longestStep == 300 && c.active == 30 * 60 + 300, "B-late", "a reading 10 minutes late counts 5 minutes, not 10 (\(c.active) s)")

        // rel-019 final (App Nap): a timer macOS throttles to one reading every 5 minutes still counts the hour of use.
        var n = RecordingReminder()
        var napped: [Int] = []
        for k in 0...12 where n.read(off, now: t0.addingTimeInterval(Double(k) * 300), calendar: calendar) { napped.append(k * 5) }
        check(napped == [60] && n.shownDay == "2026-10-12", "B-throttled", "readings 5 minutes apart: each step counts fully, shown at minute 60: \(napped)")
        // …but a 5-minute step counts only when the person is present at its reading, and never across a sleep or lock.
        var g = RecordingReminder()
        _ = g.read(off, now: t0, calendar: calendar); _ = g.read(off, now: t0.addingTimeInterval(300), calendar: calendar)
        check(g.active == 300, "B-throttled", "one 5-minute step: 300 s (\(g.active) s)")
        _ = g.read(idle, now: t0.addingTimeInterval(600), calendar: calendar)
        _ = g.read(off, now: t0.addingTimeInterval(900), calendar: calendar)
        check(g.active == 300, "B-throttled", "idle over 3 minutes at a 5-minute reading: that step and the next count nothing (\(g.active) s)")
        _ = g.read(off, now: t0.addingTimeInterval(1200), calendar: calendar)
        check(g.active == 600, "B-throttled", "then 5 minutes count again (\(g.active) s)")
        g.interrupted()
        _ = g.read(off, now: t0.addingTimeInterval(1500), calendar: calendar)
        check(g.active == 600, "B-throttled", "a lock or sleep between two 5-minute readings: that step counts nothing (\(g.active) s)")
        // A long gap is still capped: 40 minutes between two readings count 5.
        _ = g.read(off, now: t0.addingTimeInterval(1500 + 2400), calendar: calendar)
        check(g.active == 900, "B-throttled", "40 minutes between two readings count 5 minutes, not 40 (\(g.active) s)")

        // C. Once a day; the next day it can show again after its own hour; a new day starts the hour over.
        var d = RecordingReminder()
        _ = run(&d, from: t0, minutes: 61, off)
        check(d.shownDay == "2026-10-12" && run(&d, from: t0, minutes: 180, off, first: 61).isEmpty, "C-day", "3 more hours off the same day: not again")
        let next = morning(13)
        check(run(&d, from: next, minutes: 60, off).isEmpty, "C-day", "the next day: not before its own hour")
        check(run(&d, from: next, minutes: 1, off, first: 60) == [60] && d.shownDay == "2026-10-13", "C-day", "the next day after an hour of use: once more")
        var e = RecordingReminder()
        let late = calendar.date(from: DateComponents(year: 2026, month: 10, day: 12, hour: 23, minute: 20))!
        _ = run(&e, from: late, minutes: 41, off) // 23:20 to 24:00
        check(run(&e, from: late, minutes: 30, off, first: 41).isEmpty && e.active == 30 * 60, "C-day", "a new day starts the hour over (40 minutes before midnight count for nothing): \(e.active) s")
        var saved = RecordingReminder(shownDay: "2026-10-12")
        check(run(&saved, from: t0, minutes: 120, off).isEmpty, "C-day", "a day saved before (a relaunch): two hours off that day, not again")

        // D. Every exemption: no count, and the hour starts over.
        for standing: RecordingReminder.Standing in [.recording, .setupUnfinished, .timedPause, .permissionMissing, .blocked, .notApplicable] {
            var f = RecordingReminder()
            _ = run(&f, from: t0, minutes: 51, off)
            let shown = run(&f, from: t0, minutes: 120, RecordingReminder.Reading(standing: standing), first: 51)
            check(shown.isEmpty && f.active == 0, "D-exempt", "\(standing): 2 hours, no reminder, and the 50 minutes before start over")
            check(run(&f, from: t0, minutes: 59, off, first: 171).isEmpty, "D-exempt", "\(standing) then off again: a full hour from there (59 minutes: none)")
            check(!RecordingReminder.stillApplies(standing), "D-exempt", "\(standing): a reminder on screen goes")
        }
        check(RecordingReminder.stillApplies(.off), "D-exempt", "off: a reminder on screen stays")
    }

    // MARK: F. Placement

    static func placement() {
        let screen = CGRect(x: 0, y: 0, width: 1512, height: 982), visible = CGRect(x: 0, y: 0, width: 1512, height: 949)
        let item = CGRect(x: 1200, y: 949, width: 30, height: 33)
        let windows: [RecordingReminderPlacement.WindowInfo] = [
            .init(frame: CGRect(x: 100, y: 200, width: 900, height: 600), level: 0, visible: true),     // a window
            .init(frame: CGRect(x: 1100, y: 600, width: 300, height: 349), level: 25, visible: false),  // the menu panel, closed
            .init(frame: item, level: 25, visible: true)]
        let found = RecordingReminderPlacement.statusItemFrame(windows, screens: [screen])
        check(found == item, "F-place", "the menu bar item is the visible window in the menu bar strip: \(String(describing: found))")
        let size = CGSize(width: 290, height: 38)
        let o = RecordingReminderPlacement.origin(size: size, item: item, visible: visible)
        check(o == CGPoint(x: 1070, y: 905), "F-place", "under the item, centered on it, 6 pt below the menu bar: \(o)")
        let edge = RecordingReminderPlacement.origin(size: size, item: CGRect(x: 1490, y: 949, width: 22, height: 33), visible: visible)
        check(edge.x + size.width <= visible.maxX - 8, "F-place", "an item at the screen's edge: the panel stays on screen: \(edge)")
        let none = RecordingReminderPlacement.origin(size: size, item: nil, visible: visible)
        check(RecordingReminderPlacement.statusItemFrame(Array(windows.prefix(2)), screens: [screen]) == nil && none == CGPoint(x: 1214, y: 905),
              "F-place", "no item found: top right under the menu bar: \(none)")
    }

    // MARK: The real model

    /// A model on a new private history, recording off (setup finished, permissions on), with fake reads.
    static func open(_ name: String, defaults: UserDefaults = MemoryDefaults(), now: Date = morning()) async throws -> Opened {
        let memory = out.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try makePrivateDirectory(memory)
        setenv("MAC_MEM_HOME", memory.path, 1)
        let model = MemoryViewModel()
        let wake = FakeWake(), reminder = FakeReminder(now: now, defaults: defaults)
        model.noticeCenter = FakeNotices().center
        model.wakeSystem = wake.system
        model.reminderSystem = reminder.system
        model.activity.calendar = calendar
        check(!model.anotherCopyOpen, "harness", "\(name) opened its own history")
        _ = try await waitFor(3) { !model.history.busy }
        try await tick(0.1)
        model.refreshCaptureStatus()
        return Opened(model: model, wake: wake, reminder: reminder)
    }
    /// `count` minutes of readings (the clock moves a minute before each).
    static func minutes(_ o: Opened, _ count: Int) {
        for _ in 0..<count { o.reminder.now = o.reminder.now.addingTimeInterval(60); o.model.reminderTick() }
    }
    static func describe(_ o: Opened) -> String {
        "\(o.model.recordingState), standing \(o.model.reminderStanding), active \(o.model.reminderState?.active ?? -1), shows \(o.reminder.shows)"
    }

    static func inertOutsideTheApp() async throws {
        let memory = out.appendingPathComponent("inert-" + UUID().uuidString, isDirectory: true)
        try makePrivateDirectory(memory)
        setenv("MAC_MEM_HOME", memory.path, 1)
        let model = MemoryViewModel()
        _ = try await waitFor(3) { !model.history.busy }
        check(!model.reminderSystem.drives && model.reminderSystem.defaults == nil, "inert", "outside the app bundle the reminder reads nothing and shows nothing")
    }

    /// A. On the real model: the person's Stop, then an hour of use.
    static func modelHour() async throws {
        let o = try await open("hour")
        o.model.startCapture()
        check(o.model.recording, "harness", "hour: recording started: \(describe(o))")
        o.model.reminderTick()
        minutes(o, 30)
        check(o.model.reminderStanding == .recording && o.reminder.shows == 0, "A-model", "30 minutes recording: nothing: \(describe(o))")
        o.model.stopCapture()
        try await tick(0.1)
        check(o.model.reminderStanding == .off, "A-model", "the person's Stop: recording is off for the reminder: \(describe(o))")
        minutes(o, 60)
        check(o.reminder.shows == 0, "A-model", "60 readings after the Stop (59 minutes counted): no reminder yet: \(describe(o))")
        minutes(o, 1)
        check(o.reminder.shows == 1 && o.model.reminderShown, "A-model", "an hour of use after the Stop: the reminder shows: \(describe(o))")
        check(o.reminder.defaults.string(forKey: RecordingReminder.shownDayKey) == "2026-10-12", "A-model", "…and its day is saved")
    }

    /// B. On the real model: idle, the lock and sleep.
    static func modelIdleLockSleep() async throws {
        let o = try await open("idle")
        o.model.reminderTick()
        minutes(o, 20)
        o.reminder.idle = 600
        minutes(o, 30)
        check(o.model.reminderState?.active == 20 * 60, "B-model", "idle 10 minutes: those readings don't count: \(describe(o))")
        o.reminder.idle = 4
        o.wake.locked = true; o.model.suspend(.screenLock)
        minutes(o, 30)
        check(o.model.reminderState?.active == 20 * 60 && o.model.reminderStanding == .off, "B-model",
              "screen locked 30 minutes: not counted, and not a reason to start over: \(describe(o))")
        o.wake.locked = false; o.model.unsuspend(.screenLock); o.wake.runPending()
        minutes(o, 1)
        check(o.model.reminderState?.active == 20 * 60, "B-model", "the first reading after the unlock counts nothing: \(describe(o))")
        o.model.suspend(.sleep)
        o.reminder.now = o.reminder.now.addingTimeInterval(8 * 3600)
        o.model.unsuspend(.sleep); o.wake.runPending()
        o.model.reminderTick()
        check(o.model.reminderState?.active == 20 * 60, "B-model", "8 hours asleep with no reading: the first one after the wake counts nothing: \(describe(o))")
        minutes(o, 39)
        check(o.reminder.shows == 0 && o.model.reminderState?.active == 59 * 60, "B-model", "20 minutes before, 39 after: not yet: \(describe(o))")
        minutes(o, 1)
        check(o.reminder.shows == 1, "B-model", "the 60th: shown: \(describe(o))")
    }

    /// C. Once a day, across a relaunch (the saved day).
    static func modelOncePerDay() async throws {
        let defaults = MemoryDefaults()
        let o = try await open("day-1", defaults: defaults)
        o.model.reminderTick(); minutes(o, 60)
        check(o.reminder.shows == 1, "C-model", "shown after the hour: \(describe(o))")
        minutes(o, 120)
        check(o.reminder.shows == 1, "C-model", "two more hours off the same day: not again: \(describe(o))")
        let again = try await open("day-2", defaults: defaults, now: o.reminder.now)
        again.model.reminderTick(); minutes(again, 120)
        check(again.reminder.shows == 0, "C-model", "a relaunch the same day: two hours off, not again (the day is saved): \(describe(again))")
        let tomorrow = try await open("day-3", defaults: defaults, now: morning(13))
        tomorrow.model.reminderTick(); minutes(tomorrow, 60)
        check(tomorrow.reminder.shows == 1, "C-model", "the next day, after an hour: once more: \(describe(tomorrow))")
    }

    /// D. Setup unfinished.
    static func modelSetupUnfinished() async throws {
        let o = try await open("setup")
        UserDefaults.standard.register(defaults: [MemoryViewModel.setupCompletedKey: false])
        defer { UserDefaults.standard.register(defaults: [MemoryViewModel.setupCompletedKey: true]) }
        o.model.refreshCaptureStatus()
        o.model.reminderTick(); minutes(o, 180)
        check(o.model.reminderStanding == .setupUnfinished && o.reminder.shows == 0, "D-setup", "setup unfinished: three hours off, no reminder: \(describe(o))")
    }

    /// D. A timed pause, before it ends.
    static func modelTimedPause() async throws {
        let o = try await open("timed")
        o.model.startCapture()
        o.model.reminderTick(); minutes(o, 50)
        o.model.pauseFor(minutes: 120)
        check(o.model.pauseUntil != nil, "harness", "the timed pause runs: \(describe(o))")
        minutes(o, 119)
        check(o.model.reminderStanding == .timedPause && o.reminder.shows == 0, "D-timed", "a 2-hour pause, 119 minutes in: no reminder: \(describe(o))")
        o.model.stopCapture()
        try await tick(0.1)
        o.model.refreshCaptureStatus()
        check(o.model.pauseUntil == nil && o.model.reminderStanding == .off, "D-timed", "the person's Stop ends the pause: off: \(describe(o))")
        minutes(o, 59)
        check(o.reminder.shows == 0, "D-timed", "the hour counts from the Stop, not from before the pause: \(describe(o))")
    }

    /// D. A permission missing: the permission UI says that, the reminder doesn't.
    static func modelPermissionMissing() async throws {
        let o = try await open("permission")
        Seams.granted = false
        defer { Seams.granted = true }
        o.model.refreshCaptureStatus()
        o.model.reminderTick(); minutes(o, 180)
        check(o.model.reminderStanding == .permissionMissing && o.reminder.shows == 0, "D-permission", "Accessibility and Input Monitoring off: three hours, no reminder: \(describe(o))")
    }

    /// B. rel-019 final (App Nap): the model's readings 5 minutes apart count the hour; a lock between two doesn't count.
    static func modelThrottled() async throws {
        let o = try await open("throttled")
        o.model.reminderTick()
        for _ in 0..<6 { o.reminder.now = o.reminder.now.addingTimeInterval(300); o.model.reminderTick() }
        check(o.model.reminderState?.active == 30 * 60, "B-throttled-model", "6 readings 5 minutes apart: 30 minutes counted: \(describe(o))")
        o.wake.locked = true; o.model.suspend(.screenLock)
        o.reminder.now = o.reminder.now.addingTimeInterval(120)
        o.wake.locked = false; o.model.unsuspend(.screenLock); o.wake.runPending()
        o.reminder.now = o.reminder.now.addingTimeInterval(180); o.model.reminderTick()
        check(o.model.reminderState?.active == 30 * 60, "B-throttled-model", "a lock between two 5-minute readings: that step counts nothing: \(describe(o))")
        for _ in 0..<5 { o.reminder.now = o.reminder.now.addingTimeInterval(300); o.model.reminderTick() }
        check(o.reminder.shows == 0 && o.model.reminderState?.active == 55 * 60, "B-throttled-model", "55 minutes: not yet: \(describe(o))")
        o.reminder.now = o.reminder.now.addingTimeInterval(300); o.model.reminderTick()
        check(o.reminder.shows == 1, "B-throttled-model", "the 12th counted 5-minute step: shown: \(describe(o))")
    }

    /// D. rel-019 final: Input Monitoring turned on after launch (Start would open setup's Quit & Reopen): no reminder.
    static func modelReopenNeeded() async throws {
        Seams.granted = false
        let o = try await open("reopen")
        defer { Seams.granted = true }
        // The off read at launch confirmed (a read after `confirmAfter`), then Input Monitoring turned on.
        try await tick(InputMonitoringWatch.confirmAfter + 0.2)
        o.model.refreshCaptureStatus()
        Seams.granted = true
        o.model.refreshCaptureStatus()
        o.model.reminderTick(); minutes(o, 120)
        check(o.model.reminderStanding == .permissionMissing && o.reminder.shows == 0, "D-reopen",
              "Input Monitoring turned on after launch: two hours off, no reminder: \(describe(o))")
        check(o.model.setupStepForStart() == .permissions, "D-reopen", "…where Start would open setup's Permissions page (Quit & Reopen)")
    }

    /// D. rel-019 final: a change that didn't save (Start would open setup's Apps page): no reminder; saved again, it counts.
    static func modelChangeNotSaved() async throws {
        let o = try await open("unsaved")
        let saved = o.model.blockedDomains
        o.model.blockedDomains = saved.isEmpty ? "example.com" : ""
        o.model.reminderTick(); minutes(o, 120)
        check(o.model.preferenceProblem != nil && o.model.reminderStanding == .blocked && o.reminder.shows == 0, "D-unsaved",
              "a change that didn't save: two hours off, no reminder: \(describe(o))")
        check(o.model.setupStepForStart() == .apps, "D-unsaved", "…where Start would open setup's Apps page")
        o.model.blockedDomains = saved
        check(o.model.preferenceProblem == nil && o.model.reminderStanding == .off, "D-unsaved", "the saved choices back: off again: \(describe(o))")
    }

    /// E. Start Recording records, like the menu's.
    static func startButton() async throws {
        let o = try await open("start")
        let routes = Routes()
        o.model.reminderRoutes = routes.routes
        o.model.reminderTick(); minutes(o, 60)
        guard o.reminder.shows == 1, let start = o.reminder.start else { check(false, "E-start", "the reminder showed: \(describe(o))"); return }
        start()
        try await tick(0.1)
        check(o.model.recording && o.model.recordingWanted && o.model.recordingState.kind == .recording, "E-start", "Start Recording records: \(describe(o))")
        check(!o.model.reminderShown && o.reminder.hides >= 1 && routes.opened.isEmpty, "E-start", "…the panel goes and nothing opens: \(routes.opened)")
        // The menu's Start Recording on a twin, from the same state, does the same.
        let twin = try await open("start-menu")
        let menuRoutes = Routes()
        DaydreamMenuBarPanel.actions(model: twin.model, routes: menuRoutes.routes).resume()
        try await tick(0.1)
        check(twin.model.recording == o.model.recording && twin.model.recordingWanted == o.model.recordingWanted && menuRoutes.opened == routes.opened,
              "E-start", "…exactly what the menu bar's Start Recording does")
        o.model.stopCapture(); twin.model.stopCapture()
    }

    /// E. A permission turned off after it showed: the click goes where the menu's goes (setup's Permissions page).
    static func startButtonPermissionGone() async throws {
        let o = try await open("start-permission")
        let routes = Routes()
        o.model.reminderRoutes = routes.routes
        o.model.reminderTick(); minutes(o, 60)
        guard o.reminder.shows == 1, let start = o.reminder.start else { check(false, "E-path", "the reminder showed: \(describe(o))"); return }
        Seams.granted = false
        defer { Seams.granted = true }
        start()
        try await tick(0.1)
        check(!o.model.recording && routes.opened == ["onboarding"] && routes.activations == 1 && o.model.setupRequest == .permissions,
              "E-path", "Start Recording with a permission off opens setup at Permissions, as the menu does: \(routes.opened), \(String(describing: o.model.setupRequest))")
        let twin = try await open("start-permission-menu")
        let menuRoutes = Routes()
        DaydreamMenuBarPanel.actions(model: twin.model, routes: menuRoutes.routes).resume()
        try await tick(0.1)
        check(menuRoutes.opened == routes.opened && menuRoutes.activations == routes.activations && twin.model.setupRequest == o.model.setupRequest
              && twin.model.recording == o.model.recording,
              "E-path", "…the same as the menu bar's Start Recording: \(menuRoutes.opened), \(String(describing: twin.model.setupRequest))")
    }

    /// E. ✕ only hides; recording started from elsewhere takes the panel down.
    static func dismissAndOtherStart() async throws {
        let o = try await open("dismiss")
        o.model.reminderTick(); minutes(o, 60)
        o.reminder.dismiss?()
        check(!o.model.reminderShown && o.reminder.hides == 1 && !o.model.recording, "E-dismiss", "✕ hides it and starts nothing: \(describe(o))")
        let p = try await open("other-start", now: morning(14))
        p.model.reminderTick(); minutes(p, 60)
        check(p.model.reminderShown, "harness", "other-start: shown: \(describe(p))")
        p.model.startCapture()
        try await tick(0.1)
        check(p.model.recording && !p.model.reminderShown && p.reminder.hides == 1, "E-other", "recording started from the menu or the window: the panel goes: \(describe(p))")
        p.model.stopCapture()
    }
}
