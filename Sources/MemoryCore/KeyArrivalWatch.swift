import Foundation

/// claude/typing-1004 (owner laptop, public 0.1.4 on 10/04: "Recording", Chrome pages saved, no typing): an input tap
/// that macOS makes but never feeds a key. Input Monitoring turned on (or its row changed) after DayDream opened works
/// only once DayDream reopens; until then the tap gets clicks but no key downs, the app shows Recording, and nothing it
/// reads says why (CGPreflightListenEventAccess answers yes). Pure: while recording, the heartbeat hands it the
/// session's key-down counter (`CGEventSource.counterForEventType`, no permission needed and no key read) and whether
/// secure input is on; the tap tells it when a key down arrives. Keys the Mac counted with secure input off at both ends
/// of a sample, `threshold` of them and not one at the tap since recording started, mean the tap is not fed: the app
/// restarts itself once (the same restart as `PermissionRelaunch`, recording resumes after it) or says so.
public struct KeyArrivalWatch: Equatable, Sendable {
    /// Key downs the session counted with none at the tap. A password typed under secure input never counts (the tap
    /// doesn't get those keys either), and two dozen keys is more than any shortcut burst.
    public static let threshold = 24
    /// A jump bigger than this between two samples is not believed (a counter reset, a wrap).
    public static let maxStep: UInt32 = 2_000
    public private(set) var unseen = 0
    /// A key reached the tap in this recording: the tap is fed, nothing to watch.
    public private(set) var proved = false
    /// Already reported for this recording (once only).
    public private(set) var reported = false
    private var last: UInt32?
    public init() {}
    /// Recording started (a new tap): watch again.
    public mutating func start() { self = KeyArrivalWatch() }
    /// A key down reached the tap.
    public mutating func keyArrived() { proved = true; unseen = 0 }
    /// One heartbeat's sample. True exactly once, when the keys counted without reaching the tap reach `threshold`.
    public mutating func sample(counter: UInt32, secureInput: Bool) -> Bool {
        defer { last = secureInput ? nil : counter }
        guard !proved, !reported, !secureInput, let last else { return false }
        let step = counter &- last
        guard step <= Self.maxStep else { return false }
        unseen += Int(step)
        guard unseen >= Self.threshold else { return false }
        reported = true
        return true
    }
}
