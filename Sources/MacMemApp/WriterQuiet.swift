import Foundation
import MemoryCore

/// perf2-1005 (owner 10/04, "took like 10 seconds" to open; keys dropped while the note backlog ran): the app's writer
/// environment. The background note writer
/// - writes only today's moments (`pastDayNotes`: no catch-up of the 7 past days, their queued entries dropped),
/// - waits while DayDream opens (until Today is shown plus 10 s, at most a minute; `LaunchQuiet`) and while keys were typed
///   in the last `typingBurst` seconds (`quietFor`), and
/// - runs its passes and note runs at utility priority (`workPriority`), not the main thread's.
/// claude/dayeval-1005: and no model writes moment or level notes (`momentModel`; code writes them) unless the hidden
/// default `DayDreamMomentSummaries` is set.
/// Checks build their own environment and keep the old behaviour.
extension WriterEnvironment {
    static var app: WriterEnvironment {
        var e = WriterEnvironment.live
        e.momentModel = UserDefaults.standard.bool(forKey: "DayDreamMomentSummaries")
        e.pastDayNotes = false
        e.workPriority = .utility
        let typing = e.typingSeconds
        e.quietFor = { max(LaunchQuiet.remaining(), WriterIntegration.typingBurst - max(0, typing())) }
        return e
    }
}
