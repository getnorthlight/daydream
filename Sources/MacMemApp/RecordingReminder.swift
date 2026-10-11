import Foundation

// rel-019 (owner 10/10): their own DayDream sat with recording off for a day and a half without them noticing. When
// recording is off and the person has been using the Mac for about an hour, DayDream says so once: "Recording is off."
// with Start Recording (RecordingReminderPanel.swift draws it under the menu bar item).
//
// - Active time, not wall time: a minute counts only while input has been idle for at most `idleLimit`, the screen is
//   not locked, this login session is on screen and the Mac is awake. The Mac's sleep (and a lock or user switch) also
//   forgets the last read, so the time across one never counts. A step between two readings counts at most
//   `longestStep` (5 minutes), so a throttled timer doesn't stretch the hour.
// - The hour counts from when recording went off, within one calendar day: recording on, or anything that exempts the
//   reminder, starts it over, and so does a new day.
// - At most once per calendar day (the day is saved, so a relaunch never shows it twice).
// - Never while setup is unfinished, during a timed pause before it ends, while a permission is missing (the permission
//   UI says that) or Input Monitoring waits for DayDream to reopen, while something else stands in the way of Start
//   (another copy open, an import running, the download window, a change that didn't save), or while DayDream is
//   starting recording by itself (after a wake, a failed save, an import).
// Pure: the app model (MacMemApp.swift, `reminderTick`) feeds it one reading a minute and shows what it says. Foundation
// only, so a check can compile it on its own.

struct RecordingReminder: Equatable, Sendable {
    /// Where recording stands, for the reminder. Only `.off` counts.
    enum Standing: Equatable, Sendable {
        /// Off, and nothing will start it by itself: the one state the reminder is for.
        case off
        /// Recording, or DayDream starting it by itself (a wake's plan, a failed save's retries, an import ending).
        case recording
        case setupUnfinished
        /// The person's timed pause, before it ends.
        case timedPause
        /// A permission is missing (the permission UI handles it).
        case permissionMissing
        /// Something else stands in the way of Start (another copy, an import, the download window, a replacement).
        case blocked
        /// The Development Trial, the preview and the trials never remind.
        case notApplicable
    }

    /// One minute's reads.
    struct Reading: Equatable, Sendable {
        var standing: Standing
        /// Seconds since the last keyboard or mouse input (any app).
        var idle: TimeInterval
        var locked: Bool
        var asleep: Bool
        var onConsole: Bool
        init(standing: Standing, idle: TimeInterval = 0, locked: Bool = false, asleep: Bool = false, onConsole: Bool = true) {
            self.standing = standing; self.idle = idle; self.locked = locked; self.asleep = asleep; self.onConsole = onConsole
        }
        /// The person is at the Mac: awake, unlocked, on screen and not idle for more than `idleLimit`.
        var present: Bool { !asleep && !locked && onConsole && idle <= RecordingReminder.idleLimit }
    }

    /// About an hour of use with recording off.
    static let activeNeeded: TimeInterval = 3600
    /// Input idle for longer than this is not use.
    static let idleLimit: TimeInterval = 180
    /// How often the model reads.
    static let interval: TimeInterval = 60
    /// The most one reading counts. rel-019 final: 5 minutes, so a timer macOS throttles while DayDream is in the
    /// background (App Nap, recording off) still counts the use between its readings; a step counts only when both of its
    /// readings count (the person present at each: idle at most `idleLimit`, unlocked, on screen, awake) and no sleep,
    /// lock or user switch came between them (`interrupted`). A longer gap (a stalled main thread, a missed sleep notice)
    /// counts 5 minutes at most.
    static let longestStep: TimeInterval = 300
    /// The calendar day it last showed ("2026-10-10"), in the app's defaults.
    static let shownDayKey = "DaydreamRecordingReminderDayV1"

    /// Active seconds with recording off, today, since it went off.
    private(set) var active: TimeInterval = 0
    /// The last reading's time; nil after an interruption (nothing counts until the next one).
    private(set) var last: Date?
    /// The day `active` counts.
    private(set) var day: String?
    /// The day it last showed.
    private(set) var shownDay: String?

    init(shownDay: String? = nil) { self.shownDay = shownDay }

    static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// One reading. True: show the reminder now (it counts as shown today from here).
    /// A minute counts only between two readings that both count: recording off, the person present, the same day.
    mutating func read(_ reading: Reading, now: Date, calendar: Calendar) -> Bool {
        let today = Self.dayKey(now, calendar: calendar)
        let previous = day == today ? last : nil
        last = nil
        if day != today { day = today; active = 0 }
        guard reading.standing == .off else { active = 0; return false }
        guard reading.present else { return false }
        last = now
        guard let previous, now > previous else { return false }
        active += min(now.timeIntervalSince(previous), Self.longestStep)
        guard active >= Self.activeNeeded, shownDay != today else { return false }
        shownDay = today
        active = 0
        return true
    }

    /// The Mac went to sleep, the screen locked or the person switched users: the time until the next reading is not use.
    mutating func interrupted() { last = nil }

    /// A reminder on screen stays only while recording is still off as it was.
    static func stillApplies(_ standing: Standing) -> Bool { standing == .off }
}
