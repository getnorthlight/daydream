import Foundation
import PrivacyPolicy

/// claude/chrome-offmain-1003 (PERF-1003 risk 1: an allowed Chrome key cost about 67 ms of DayDream's main thread in the
/// owner test model, its join and per-key check being Apple Events and Accessibility reads made on main).
///
/// Capture's event tap runs on its own thread (`EventCapture`'s tap thread) when a typing route wants its key work off
/// the main thread. Every event is still handled on the main thread, one at a time and in the tap's order, while the
/// tap thread waits (`DispatchQueue.main.sync`), exactly as when the tap ran on main. For a key down, the main thread's
/// handling may hand back one piece of work (`offer`): the website typing route's handling of that key (its join, its
/// per-key check, the key's characters and any save). The tap thread runs that work at once, on the route's own serial
/// executor (`TypingRouteExecutor`), before it returns from the tap callback and before it takes the next event. So:
/// - the order of every key, click and boundary the route sees, and when it sees them, are what they were on main;
/// - a key's characters are still read only inside the tap callback that delivered the key, only after its join
///   allowed it, and the event is never copied or queued past that callback;
/// - only the main thread is free while the route waits on Chrome.
/// Nothing here reads a key, a character or the OS. Public builds without the owner switch keep the tap on main.
public enum TypingKeyHandoff {
    /// The work for one key: given the key's characters (read only if the work asks), run it to the end.
    public typealias Work = (_ characters: () throws -> String) -> Void
    private static let lock = NSLock()
    private static var armed = false
    private static var pending: Work?

    /// Whether website typing's key work runs off the main thread (the tap on its own thread, the route on its executor):
    /// builds with the owner switch, unless the person's defaults set `onMainDefaultsKey` (a way back, read once).
    public static let offMainEnabled: Bool = OwnerTyping.enabled && !UserDefaults.standard.bool(forKey: onMainDefaultsKey)
    public static let onMainDefaultsKey = "DayDreamWebTypingOnMainThread"

    /// The tap thread, on the main thread, before handling one event: a key's route may hand its work back.
    public static func arm() { lock.lock(); armed = true; pending = nil; lock.unlock() }
    /// The route, on the main thread, while the tap thread waits: true when the tap thread will run `work` before its
    /// next event; false when no tap thread is waiting (a caller on main itself: run the work there, as before).
    public static func offer(_ work: @escaping Work) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard armed, pending == nil else { return false }
        pending = work
        return true
    }
    /// The tap thread, on the main thread, after handling the event: the work handed back, if any. Disarms.
    public static func take() -> Work? {
        lock.lock(); defer { armed = false; pending = nil; lock.unlock() }
        return pending
    }
}

/// claude/chrome-offmain-1003: one serial executor off the main thread, where the synchronous website typing route keeps
/// all of its state and does all of its work (keys, clicks, boundaries, timers, its Chrome witness's reads). Work from
/// the main thread is queued in the order it happens (`async`); the tap thread runs a key's work and waits for it
/// (`sync`). Nothing on this executor ever waits on the main thread or the tap thread, so neither wait can deadlock.
public final class TypingRouteExecutor: @unchecked Sendable {
    public let queue: DispatchQueue
    private let key = DispatchSpecificKey<ObjectIdentifier>()
    public init(label: String = "daydream.web-typing.route") {
        queue = DispatchQueue(label: label, qos: .userInteractive)
        queue.setSpecific(key: key, value: ObjectIdentifier(queue))
    }
    /// True while running on this executor.
    public var isCurrent: Bool { DispatchQueue.getSpecific(key: key) == ObjectIdentifier(queue) }
    public func async(_ work: @escaping () -> Void) { queue.async(execute: work) }
    /// Runs `work` here and waits for it (at once when already here). Never called from this executor's own work on
    /// another executor's behalf, and never from the main thread while the main thread holds something it needs.
    public func sync<T>(_ work: () throws -> T) rethrows -> T { isCurrent ? try work() : try queue.sync(execute: work) }
    public func after(_ seconds: TimeInterval, _ work: @escaping () -> Void) {
        queue.asyncAfter(deadline: .now() + max(0, seconds), execute: work)
    }
}

/// claude/chrome-offmain-1003: the keyboard input source rule (`AccessibilityReader.keyboardInputIsDirect`) reads Text
/// Input Sources, which belong to the main thread. The main thread reads it for every key and at every input source
/// change, before it hands that work over; work on the route's executor reads the last value the main thread saw.
/// Starts false (not direct: nothing is proven until the main thread has read it).
public final class DirectInputMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    public init() {}
    public func read(_ live: () -> Bool) -> Bool {
        guard Thread.isMainThread else { lock.lock(); defer { lock.unlock() }; return value }
        let now = live()
        lock.lock(); value = now; lock.unlock()
        return now
    }
}
