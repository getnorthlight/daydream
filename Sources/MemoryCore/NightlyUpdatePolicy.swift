import Foundation

/// Calendar policy only. Sparkle owns all downloads, verification and installation.
/// Caller persists the returned night token before dispatching a check/restart.
public struct NightlyUpdatePolicy {
    public var calendar:Calendar
    public init(calendar:Calendar = .autoupdatingCurrent) { self.calendar=calendar }
    public func night(_ now:Date)->Date? {
        calendar.date(bySettingHour:3,minute:0,second:0,of:now,matchingPolicy:.nextTime,repeatedTimePolicy:.first,direction:.forward)
    }
    public func nextNight(after now:Date)->Date? {
        calendar.nextDate(after:now,matching:DateComponents(hour:3,minute:0,second:0),matchingPolicy:.nextTime,repeatedTimePolicy:.first)
    }
    public func token(_ now:Date)->String {
        let c=calendar.dateComponents([.era,.year,.month,.day],from:now)
        return "\(c.era ?? 0)-\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }
    public func mayCheck(now:Date,lastNight:String?,enabled:Bool,configured:Bool,launchOrWake:Bool)->Bool {
        guard enabled, configured, lastNight != token(now), let due=night(now), now >= due else { return false }
        return launchOrWake || now.timeIntervalSince(due) < 3600
    }
    public func mayInstall(now:Date,stagedAt:Date,lastAttempt:String?,enabled:Bool,configured:Bool,criticalWrites:Bool,prepared:Bool)->Bool {
        guard enabled, configured, !criticalWrites, prepared, lastAttempt != token(now), let due=night(now), now >= due, now.timeIntervalSince(due)<3600 else { return false }
        // A daytime catch-up download must wait for a later night's window.
        guard let stagedNight=night(stagedAt) else { return false }
        return stagedAt < due || (stagedAt >= due && stagedAt.timeIntervalSince(stagedNight)<3600)
    }
}
