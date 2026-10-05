import Foundation

/// perf2-1005 (owner laptop, public 0.1.4 on 10/04: "Input tap turned off by macOS (timeout)" seven times in an hour, each
/// after a main-thread stall of about a second). The input tap runs on its own thread (`EventCapture`'s tap thread) and
/// handed every event to the main thread with `DispatchQueue.main.sync`, so the tap callback took as long as the main
/// thread was busy, and macOS turns off a tap whose callback takes too long: every key and click after that went unseen
/// until the heartbeat turned it back on.
///
/// Now the tap thread waits for the main thread at most `deadline`:
/// - main reaches the event in time: it is handled there exactly as before (in order, the tap thread waiting, a key's
///   characters read only inside its own callback, the event never kept past it);
/// - main already started on it when the deadline passes: the tap thread waits for it to finish, as before;
/// - main hasn't reached it: the event is never handled (its block, when main gets to it, touches no event). It and
///   every event after it until main catches up are counted, without waiting, as missed, and main is told once
///   (`gap`), before any later event: a gap in the input, judged like a tap macOS turned off (typing parked, no late key
///   read across it), except that the tap stays on.
/// Nothing here reads a key, a character, a location or the OS: only whether an event was a key down.
public final class TapMainHandoff: @unchecked Sendable {
    public struct Missed: Equatable, Sendable {
        public var events = 0
        public var keys = 0
        public init(events: Int = 0, keys: Int = 0) { self.events = events; self.keys = keys }
    }
    /// How long the tap thread waits for the main thread to reach an event. macOS turns off a tap at about a second;
    /// a key handled later than `EventCapture.maxKeyLagNanoseconds` (150 ms) is already late.
    public static let defaultDeadline: TimeInterval = 0.3
    public let deadline: TimeInterval
    private let lock = NSLock()
    /// An event main hadn't reached by its deadline, main not yet at its block: later events are missed without waiting.
    private var backlog = false
    private var missed = Missed()
    /// Missed key downs main hasn't been told of yet (the heartbeat's key-arrival watch reads it).
    public var pendingMissedKeys: Int { lock.lock(); defer { lock.unlock() }; return missed.keys }
    public init(deadline: TimeInterval = TapMainHandoff.defaultDeadline) { self.deadline = deadline }

    private final class Slot<T> {
        /// 0: posted, 1: main is handling it, 2: missed (main never handles it).
        var state = 0
        var result: T?
        let done = DispatchSemaphore(value: 0)
    }

    /// On the tap thread, for one event. `post` puts a block on the main thread's queue (`DispatchQueue.main.async`);
    /// `handle` runs there when main reaches the event in time and its result is returned; nil when the event was missed.
    /// `gap` runs on main, once per run of missed events, before anything after them.
    public func deliver<T>(key: Bool, post: (@escaping () -> Void) -> Void, handle: @escaping () -> T,
                           gap: @escaping (Missed) -> Void) -> T? {
        lock.lock()
        if backlog {
            missed.events += 1; if key { missed.keys += 1 }
            lock.unlock()
            return nil
        }
        lock.unlock()
        let slot = Slot<T>()
        post { [self] in
            lock.lock()
            if slot.state == 2 {
                let m = missed
                missed = Missed(); backlog = false
                lock.unlock()
                gap(m)
                return
            }
            slot.state = 1
            lock.unlock()
            slot.result = handle()
            slot.done.signal()
        }
        if slot.done.wait(timeout: .now() + deadline) == .success { return slot.result }
        lock.lock()
        if slot.state == 0 {
            slot.state = 2; backlog = true
            missed.events += 1; if key { missed.keys += 1 }
            lock.unlock()
            return nil
        }
        lock.unlock()
        // Main started on it before the deadline: it finishes it, as before.
        slot.done.wait()
        return slot.result
    }
}
