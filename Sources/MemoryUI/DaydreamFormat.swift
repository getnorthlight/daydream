import Foundation
import SwiftUI

/// Numbers, times and day titles in the DayDream copy deck's exact forms.
///
/// Durations are spans (first to last observation), never time spent, so callers label
/// them "observed from … to …" and never add them up. The copy deck is English only:
/// dates and times use en_US_POSIX with fixed patterns and counts use en_US grouping,
/// so every string matches the deck on any system locale.
public enum DaydreamFormat {
    /// Compact span: "1h 45m", "12m", "2h", in whole minutes rounded down (a span is never
    /// overstated). nil under one minute (hide the pill).
    public static func duration(_ s: TimeInterval) -> String? {
        guard s.isFinite, s >= 60 else { return nil }
        return compact(minutes: Int((s / 60).rounded(.down)))
    }

    /// Spelled-out span for sentences and VoiceOver: "1 hour 45 minutes", "12 minutes" (rounded down).
    public static func spokenDuration(_ s: TimeInterval) -> String {
        guard s.isFinite, s >= 60 else { return "less than a minute" }
        return spoken(minutes: Int((s / 60).rounded(.down)))
    }

    /// The duration pill beside a `range`: the minutes between the two ends as `range` prints
    /// them (seconds dropped), so "2:30–3:20 PM" always pairs with "50m". nil when the real
    /// span is under a minute.
    public static func duration(from a: Date, to b: Date) -> String? {
        displayedMinutes(a, b).map(compact(minutes:))
    }

    /// Spoken form of `duration(from:to:)`: "50 minutes"; "less than a minute" under a minute.
    public static func spokenDuration(from a: Date, to b: Date) -> String {
        displayedMinutes(a, b).map(spoken(minutes:)) ?? "less than a minute"
    }

    /// "4:36 PM".
    public static func time(_ d: Date, _ tz: TimeZone) -> String {
        formatter("h:mm a", tz).string(from: d)
    }

    /// "9:55–11:40 AM" or "11:40 AM–12:10 PM" (U+2013, no spaces). A single time when both ends read the same.
    public static func range(_ a: Date, _ b: Date, _ tz: TimeZone) -> String {
        let (lower, upper) = a <= b ? (a, b) : (b, a)
        let start = time(lower, tz), end = time(upper, tz)
        if start == end { return start }
        let clock = formatter("h:mm", tz), meridiem = formatter("a", tz)
        if meridiem.string(from: lower) == meridiem.string(from: upper) { return clock.string(from: lower) + "\u{2013}" + end }
        return start + "\u{2013}" + end
    }

    /// Spoken range for VoiceOver and help: "2:30 to 3:20 PM", as in "Observed from 2:30 to 3:20 PM".
    public static func spokenRange(_ a: Date, _ b: Date, _ tz: TimeZone) -> String {
        range(a, b, tz).replacingOccurrences(of: "\u{2013}", with: " to ")
    }

    /// "1,204", or "1,204+" when the count is a lower bound (VoiceOver: "at least 1,204").
    public static func count(_ n: Int, complete: Bool = true) -> String {
        (grouping.string(from: NSNumber(value: n)) ?? String(n)) + (complete ? "" : "+")
    }

    /// "12 moments remembered today", "1 moment remembered yesterday". nil for 0: hide the line.
    /// `.day("Monday")` reads "remembered on Monday". `complete: false` (a partial day) marks the
    /// count as a lower bound: "412+ moments remembered today"; pair it with the partial footnote.
    public static func momentsRemembered(_ n: Int, day: DayWord = .today, complete: Bool = true) -> String? {
        guard n > 0 else { return nil }
        let noun = n == 1 && complete ? "moment" : "moments"
        return count(n, complete: complete) + " " + noun + " remembered " + day.phrase
    }

    /// Day title strings (Recall's day groups, "Nothing found back to …"). One short form for every older day
    /// (owner 10/2: "Wednesday  September 30" and "Sep 14  2026" read oddly beside Today):
    /// - today: ("Today", "Tuesday, September 22", "Tue, Sep 22")
    /// - yesterday: ("Yesterday", "Monday, September 21", "Mon, Sep 21")
    /// - older (or later than today): ("Sun, Sep 20", "Sunday, September 20", "Sun, Sep 20"); the year is Recall's
    ///   section detail when it isn't this year's.
    public static func dayTitle(_ day: Date, now: Date, calendar: Calendar) -> (title: String, date: String, narrowDate: String) {
        let tz = calendar.timeZone
        let age = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: calendar.startOfDay(for: now)).day ?? Int.max
        let full = formatter("EEEE, MMMM d", tz).string(from: day), narrow = formatter("EEE, MMM d", tz).string(from: day)
        switch age {
        case 0: return ("Today", full, narrow)
        case 1: return ("Yesterday", full, narrow)
        default: return (narrow, full, narrow)
        }
    }

    /// The main window's day header and its detail's back button: "Today" for today, else the day as the calendar
    /// tile beside it reads it, "Thu, Oct 1" (", 2025" added for another year). Every day is drawn as Today is: the
    /// tile and one title, never a second date line (owner 10/2).
    public static func dayHeader(_ day: Date, now: Date, calendar: Calendar) -> String {
        let tz = calendar.timeZone
        if calendar.isDate(day, inSameDayAs: now) { return "Today" }
        let short = formatter("EEE, MMM d", tz).string(from: day)
        return calendar.component(.year, from: day) == calendar.component(.year, from: now)
            ? short : short + ", " + formatter("yyyy", tz).string(from: day)
    }

    /// A day as a destination ("Show in Today", "Show in Monday", "Show in Sep 14"):
    /// "Today", the weekday for 1–6 days ago, else "MMM d".
    public static func dayName(_ day: Date, now: Date, calendar: Calendar) -> String {
        let tz = calendar.timeZone
        let age = calendar.dateComponents([.day], from: calendar.startOfDay(for: day), to: calendar.startOfDay(for: now)).day ?? Int.max
        switch age {
        case 0: return "Today"
        case 1...6: return formatter("EEEE", tz).string(from: day)
        default: return formatter("MMM d", tz).string(from: day)
        }
    }

    /// Morning before 12:00, afternoon 12:00–16:59, evening from 17:00, in the calendar's time zone.
    public static func dayPart(_ d: Date, calendar: Calendar) -> DayPart {
        let hour = calendar.component(.hour, from: d)
        if hour < 12 { return .morning }
        return hour < 17 ? .afternoon : .evening
    }

    /// Minutes between the ends truncated to the minute, as `time` prints them; nil when the real
    /// span is under a minute.
    private static func displayedMinutes(_ a: Date, _ b: Date) -> Int? {
        let span = abs(b.timeIntervalSince(a))
        guard span.isFinite, span >= 60 else { return nil }
        func minute(_ d: Date) -> Double { (d.timeIntervalSinceReferenceDate / 60).rounded(.down) }
        return Int(abs(minute(b) - minute(a)))
    }
    private static func compact(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        if h == 0 { return "\(m)m" }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
    private static func spoken(minutes: Int) -> String {
        let h = minutes / 60, m = minutes % 60
        let hours = h == 1 ? "1 hour" : "\(h) hours", mins = m == 1 ? "1 minute" : "\(m) minutes"
        if h == 0 { return mins }
        return m == 0 ? hours : hours + " " + mins
    }
    /// One formatter per pattern and zone, made once (fix/scroll-perf): a new `DateFormatter` costs tens of
    /// microseconds, and every Focus List row asked for several per redraw (its time, its range, its spoken range),
    /// about a quarter of a whole-list redraw on a full day. The formatters are only read after they are made
    /// (formatting is thread-safe), so every caller shares them.
    private static func formatter(_ pattern: String, _ tz: TimeZone) -> DateFormatter {
        formatters.formatter(pattern, tz)
    }
    private static let formatters = FormatterCache()
    private final class FormatterCache: @unchecked Sendable {
        private let lock = NSLock()
        private var made: [String: DateFormatter] = [:]
        func formatter(_ pattern: String, _ tz: TimeZone) -> DateFormatter {
            let key = pattern + "\u{0}" + tz.identifier
            lock.lock(); defer { lock.unlock() }
            if let f = made[key] { return f }
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.calendar = Calendar(identifier: .gregorian)
            // The zone as named now (an autoupdating zone would drift from the key it is kept under).
            f.timeZone = TimeZone(identifier: tz.identifier) ?? tz
            f.dateFormat = pattern
            made[key] = f
            return f
        }
    }
    private static let grouping: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = Locale(identifier: "en_US"); f.numberStyle = .decimal; f.usesGroupingSeparator = true
        return f
    }()
}

public enum DayPart: String, CaseIterable, Sendable {
    case morning, afternoon, evening
    public var title: String {
        switch self {
        case .morning: return "Morning"
        case .afternoon: return "Afternoon"
        case .evening: return "Evening"
        }
    }
    /// SF Symbols 4 names (macOS 13).
    public var symbol: String {
        switch self {
        case .morning: return "sunrise"
        case .afternoon: return "sun.max"
        case .evening: return "moon"
        }
    }
}

/// Which day a "remembered" count refers to. `.day` takes a day name ("Monday").
public enum DayWord: Equatable, Sendable {
    case today, yesterday, day(String)
    var phrase: String {
        switch self {
        case .today: return "today"
        case .yesterday: return "yesterday"
        case .day(let name): return "on " + name
        }
    }
}

private struct DaydreamNowKey: EnvironmentKey { static let defaultValue: Date? = nil }
private struct DaydreamStaticKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// The clock views draw with. nil = the live clock; renders and checks set a fixed instant.
    public var daydreamNow: Date? {
        get { self[DaydreamNowKey.self] }
        set { self[DaydreamNowKey.self] = newValue }
    }
    /// Deterministic drawing for renders and checks: the kit treats it like Reduce Motion
    /// (no skeleton shimmer; the live dot never moves either way).
    public var daydreamStatic: Bool {
        get { self[DaydreamStaticKey.self] }
        set { self[DaydreamStaticKey.self] = newValue }
    }
}
