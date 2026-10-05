import Foundation
import os

/// perf2-1005 (owner 10/04, "took like 10 seconds" to open): launch milestones, each logged once per launch with the time
/// since the process started, so a launch can be timed from the log alone (Console or `log show`, subsystem
/// `com.getnorthlight.daydream`, category `launch`). Names and milliseconds only: never a title, a path or anything typed.
/// With `DAYDREAM_LAUNCH_TRACE=1` in the environment (the launch measurement's test copy) each line also goes to stderr.
public enum LaunchTrace {
    private static let log = Logger(subsystem: "com.getnorthlight.daydream", category: "launch")
    private static let lock = NSLock()
    private static var seen = Set<String>()
    private static let echo = ProcessInfo.processInfo.environment["DAYDREAM_LAUNCH_TRACE"] == "1"
    /// The process's start (kernel), as a wall time.
    public static let processStart: Date = {
        var info = kinfo_proc(), size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date() }
        let t = info.kp_proc.p_starttime
        return Date(timeIntervalSince1970: Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000)
    }()
    /// Milliseconds since the process started.
    public static var elapsed: Int { Int(Date().timeIntervalSince(processStart) * 1000) }
    /// The main thread's longest stall in the first `seconds` of the launch (a background thread pings it every 20 ms),
    /// logged once at the end ("launch main.longestStall"), with when it ended. Started once (the launch session).
    public static func watchMain(seconds: TimeInterval = 20) {
        lock.lock(); let first = seen.insert("watch").inserted; lock.unlock()
        guard first else { return }
        Thread.detachNewThread {
            var longest = 0.0, longestEnd = 0, total = 0.0
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                let sent = Date(), done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async { done.signal() }
                done.wait()
                let gap = Date().timeIntervalSince(sent)
                if gap > 0.1 { total += gap }
                if gap > longest { longest = gap; longestEnd = elapsed }
                Thread.sleep(forTimeInterval: 0.02)
            }
            let ms = Int(longest * 1000), blocked = Int(total * 1000)
            log.notice("launch main.longestStall \(ms, privacy: .public) ms ending +\(longestEnd, privacy: .public) ms; stalls over 100 ms \(blocked, privacy: .public) ms in all")
            if echo { FileHandle.standardError.write(Data("LAUNCH main.longestStall \(ms) ms ending +\(longestEnd) ms; over-100ms stalls \(blocked) ms in all\n".utf8)) }
        }
    }
    /// Logs `name` the first time it is reached in this launch.
    public static func mark(_ name: StaticString) {
        let key = "\(name)"
        lock.lock(); let first = seen.insert(key).inserted; lock.unlock()
        guard first else { return }
        let ms = elapsed
        log.notice("launch \(key, privacy: .public) +\(ms, privacy: .public) ms")
        if echo { FileHandle.standardError.write(Data("LAUNCH \(key) +\(ms) ms\n".utf8)) }
    }
}

/// perf2-1005 (owner 10/04): background note work waits while DayDream opens: until Today is shown plus `afterToday`
/// seconds, or `cap` seconds after the process started when no window shows Today (a launch at login).
public enum LaunchQuiet {
    public static let afterToday: TimeInterval = 10
    public static let cap: TimeInterval = 60
    private static let lock = NSLock()
    private static var todayShownAt: Date?
    /// Today's page has its day (the first time only).
    public static func todayShown(at now: Date = Date()) {
        lock.lock(); if todayShownAt == nil { todayShownAt = now }; lock.unlock()
    }
    /// Seconds background note work still waits for the launch (0: none).
    public static func remaining(now: Date = Date()) -> TimeInterval {
        lock.lock(); let shown = todayShownAt; lock.unlock()
        let end = min(shown.map { $0.addingTimeInterval(afterToday) } ?? .distantFuture, LaunchTrace.processStart.addingTimeInterval(cap))
        return max(0, end.timeIntervalSince(now))
    }
}
