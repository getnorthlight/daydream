import Foundation

/// The ISO 8601 reads and writes behind `timestamp()`, `iso()` and `isoPrecise()`, which run on hot paths: every
/// moment of Today's snapshot on the main actor, every action of a day's layers, and the timeline. Making a new
/// `ISO8601DateFormatter` per call cost about 50 µs to write and 180 µs to read a whole-second time (two
/// formatters, the fractional one failing first), so:
/// - the two forms DayDream writes, "yyyy-MM-ddTHH:mm:ssZ" (`iso`) and "yyyy-MM-ddTHH:mm:ss.SSSZ" (`isoPrecise`), are
///   read directly, bit for bit the value the formatter gives (years 1600 and later, where the formatter's calendar is
///   Gregorian);
/// - anything else goes to the same two formatters as before, in the same order, made once and used under a lock
///   (`ISO8601DateFormatter` is not documented as safe to share across threads);
/// - writes use one formatter of each kind, under the same lock.
/// scripts/store-perf-checks.swift compares every path with the old per-call functions.
enum ISOTimestamp {
    private static let lock = NSLock()
    /// Default options: `iso()` and the whole-second read.
    private static let whole = ISO8601DateFormatter()
    /// Default options plus fractional seconds: the first read, as before.
    private static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions.insert(.withFractionalSeconds); return f
    }()
    /// `isoPrecise()`.
    private static let precise: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()

    static func string(_ date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return whole.string(from: date)
    }
    static func preciseString(_ date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return precise.string(from: date)
    }
    static func date(_ text: String) -> Date? {
        if let date = canonical(text) { return date }
        lock.lock(); defer { lock.unlock() }
        return fractional.date(from: text) ?? whole.date(from: text)
    }

    /// nil unless `text` is exactly "yyyy-MM-ddTHH:mm:ssZ" or "yyyy-MM-ddTHH:mm:ss.SSSZ" with a valid Gregorian date
    /// and time, year 1600 or later; the caller then asks the formatters, so nothing that parsed before stops parsing.
    static func canonical(_ text: String) -> Date? {
        var text = text
        return text.withUTF8 { b -> Date? in
            let n = b.count
            guard n == 20 || n == 24, b[4] == 0x2D, b[7] == 0x2D, b[10] == 0x54, b[13] == 0x3A, b[16] == 0x3A, b[n - 1] == 0x5A else { return nil }
            func number(_ from: Int, _ length: Int) -> Int? {
                var value = 0
                for i in from..<(from + length) {
                    let digit = b[i] &- 0x30
                    guard digit < 10 else { return nil }
                    value = value * 10 + Int(digit)
                }
                return value
            }
            guard let y = number(0, 4), let mo = number(5, 2), let d = number(8, 2),
                  let h = number(11, 2), let mi = number(14, 2), let s = number(17, 2) else { return nil }
            var ms = 0
            if n == 24 {
                guard b[19] == 0x2E, let fraction = number(20, 3) else { return nil }
                ms = fraction
            }
            let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
            let days = [31, leap ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            guard y >= 1600, (1...12).contains(mo), d >= 1, d <= days[mo - 1], h < 24, mi < 60, s < 60 else { return nil }
            // Days since 1970-01-01 in the proleptic Gregorian calendar (days from civil; y >= 1600, so no negative era).
            let yy = mo <= 2 ? y - 1 : y, era = yy / 400, yoe = yy - era * 400
            let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
            let sinceEpoch = era * 146_097 + yoe * 365 + yoe / 4 - yoe / 100 + doy - 719_468
            let milliseconds = Double((sinceEpoch * 86_400 + h * 3_600 + mi * 60 + s) * 1_000 + ms)
            // Milliseconds since 1970, then to the reference date: bit for bit what the formatter returns (checked).
            return Date(timeIntervalSinceReferenceDate: milliseconds / 1_000.0 - 978_307_200.0)
        }
    }
}
