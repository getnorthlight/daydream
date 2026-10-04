import Foundation
import CSQLite

// gold r3-store (golden test 5, gate item 5): the main thread never waits long for the history.
//
// The recorder's connection is one SQLite connection behind one lock (`MemoryStore.lock`), used by the main thread
// (every capture save, the 0.5 s heartbeat, the menus) and by background work (summaries, day and timeline reads).
// Two things could hold the main thread up for as long as another connection held the file (up to 1.5 s a statement):
//   1. the main thread's own statement waiting for another connection's lock (an AI app's read, a backup, another
//      process writing), and
//   2. the main thread waiting for the store's lock while a background thread held it, itself waiting in SQLite for
//      another connection, or taking the lock again and again between short statements (the lock doesn't queue).
// `StoreWait.bounded` bounds (1) for the paths that ask for it (capture saves, the heartbeat, the status refresh): within
// the scope this thread waits at most its budget for other connections in all, and the caller decides what to do with
// a save that couldn't go in yet (the recorder writes it a moment later, off the main thread, in a bounded scope too).
// `StoreLock` and the busy handler fix (2): background work that can simply run again (`StoreWait.lettingMainIn`: the
// timeline, the Forget preview, the summary queue) gives up its wait in SQLite at once while the main thread or a capture
// save written later waits for the lock (its statement fails busy, and it runs again), and any other background thread
// about to take the lock lets such a waiting thread in first. Otherwise a capture save written later, waiting for the
// lock with the session's lock held, would hold the heartbeat up behind a slow reader.

/// The store's lock: recursive, like the NSRecursiveLock it replaces, and it knows when a thread that mustn't wait long
/// waits for it: the main thread, or a capture save written a moment later (a thread inside `StoreWait.bounded`).
final class StoreLock: @unchecked Sendable {
    private let inner = NSRecursiveLock()
    private let state: UnsafeMutablePointer<os_unfair_lock> = {
        let p = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1); p.initialize(to: os_unfair_lock()); return p
    }()
    private var mainWaiters = 0
    private var urgentWaiters = 0
    private var owner: pthread_t?
    private var depth = 0
    /// How long a background thread about to take the lock lets a waiting urgent thread go first, at most.
    static let deferLimit: TimeInterval = 0.05
    deinit { state.deinitialize(count: 1); state.deallocate() }
    func lock() {
        let main = Thread.isMainThread
        let urgent = main || StoreWait.current != nil
        if !urgent, !heldHere, urgentIsWaiting {
            // Not held by this thread (taking it again inside a statement or transaction never waits): let the urgent
            // thread have it first, for a moment at most (a lock that doesn't queue its waiters would otherwise go back
            // to this thread between two of its short statements).
            let end = DispatchTime.now().uptimeNanoseconds + UInt64(Self.deferLimit * 1e9)
            while urgentIsWaiting && DispatchTime.now().uptimeNanoseconds < end { usleep(200) }
        } else if urgent, !main, !heldHere, mainIsWaiting {
            // A capture save written later lets the main thread go first, the same way.
            let end = DispatchTime.now().uptimeNanoseconds + UInt64(Self.deferLimit * 1e9)
            while mainIsWaiting && DispatchTime.now().uptimeNanoseconds < end { usleep(200) }
        }
        if urgent, !inner.try() {
            os_unfair_lock_lock(state); urgentWaiters += 1; if main { mainWaiters += 1 }; os_unfair_lock_unlock(state)
            inner.lock()
            os_unfair_lock_lock(state); urgentWaiters -= 1; if main { mainWaiters -= 1 }; os_unfair_lock_unlock(state)
        } else if !urgent {
            inner.lock()
        }
        os_unfair_lock_lock(state)
        if depth == 0 { owner = pthread_self() }
        depth += 1
        os_unfair_lock_unlock(state)
    }
    func unlock() {
        os_unfair_lock_lock(state)
        depth -= 1
        if depth == 0 { owner = nil }
        os_unfair_lock_unlock(state)
        inner.unlock()
    }
    /// The main thread is waiting for this lock now.
    var mainIsWaiting: Bool { os_unfair_lock_lock(state); defer { os_unfair_lock_unlock(state) }; return mainWaiters > 0 }
    /// The main thread, or a capture save written later, is waiting for this lock now.
    var urgentIsWaiting: Bool { os_unfair_lock_lock(state); defer { os_unfair_lock_unlock(state) }; return urgentWaiters > 0 }
    private var heldHere: Bool {
        os_unfair_lock_lock(state); defer { os_unfair_lock_unlock(state) }
        guard let owner else { return false }
        return pthread_equal(owner, pthread_self()) != 0
    }
}

/// A connection's wait for another connection's lock (SQLite's busy handler), in place of `sqlite3_busy_timeout`: the
/// same waits (1, 2, 5, 10 … 100 ms) up to the connection's patience, except that
/// - inside a `StoreWait.bounded` scope this thread waits at most what is left of the scope's budget, and
/// - a background thread inside `StoreWait.lettingMainIn` gives up at once while the main thread (or a capture save
///   written later) waits for the store's lock (`StoreLock`), and tries again once it has had it.
final class BusyWait: @unchecked Sendable {
    /// The connection's patience (1.5 s; launch's preparation waits longer). Changed only under the store's lock.
    var patienceMs: Double
    let lock: StoreLock
    /// When the current lock wait began (the handler's first call for it). Used only under the store's lock.
    fileprivate var started: UInt64 = 0
    fileprivate var slept: Double = 0
    init(patienceMs: Double, lock: StoreLock) { self.patienceMs = patienceMs; self.lock = lock }
    func install(_ db: OpaquePointer?) {
        sqlite3_busy_handler(db, busyWaitHandler, Unmanaged.passUnretained(self).toOpaque())
    }
}

private let busyDelays: [Double] = [1, 2, 5, 10, 15, 20, 25, 25, 25, 50, 50, 100]
private func busyWaitHandler(_ context: UnsafeMutableRawPointer?, _ count: Int32) -> Int32 {
    guard let context else { return 0 }
    let wait = Unmanaged<BusyWait>.fromOpaque(context).takeUnretainedValue()
    let now = DispatchTime.now().uptimeNanoseconds
    if count == 0 { wait.started = now; wait.slept = 0 }
    let main = Thread.isMainThread
    if !main && StoreWait.lettingMainIn && wait.lock.urgentIsWaiting {
        StoreWait.noteYield()
        return 0
    }
    let elapsed = Double(now - wait.started) / 1e6
    var limit = wait.patienceMs
    let scope = StoreWait.current
    var bounded = false
    if let scope, scope.remainingMs + elapsed < limit { limit = scope.remainingMs + elapsed; bounded = true }
    guard elapsed < limit else {
        if bounded { scope?.heldUp = true; scope?.remainingMs = 0 }
        return 0
    }
    var delay = Int(count) < busyDelays.count ? busyDelays[Int(count)] : 100
    // A background thread looks again for a main thread waiting for the lock every few milliseconds.
    if !main { delay = min(delay, 5) }
    delay = min(delay, limit - elapsed)
    if delay > 0 { usleep(useconds_t(delay * 1000)) }
    if let scope {
        let spent = Double(DispatchTime.now().uptimeNanoseconds - now) / 1e6
        scope.remainingMs = max(0, scope.remainingMs - spent)
    }
    return 1
}

public enum StoreWait {
    /// How long the main thread waits, at most, for another connection's lock in the paths that bound it (capture saves,
    /// the heartbeat, the status refresh, typing's refresh): 25 ms, well under a frame's worth of noticeable delay.
    public static let mainBudget: TimeInterval = 0.025
    /// A scope in which this thread waits at most `remainingMs` in all for other connections' locks.
    final class Scope {
        var remainingMs: Double
        /// A statement in the scope gave up because the budget ran out (the history was held by another connection).
        var heldUp = false
        init(_ ms: Double) { remainingMs = ms }
    }
    private static let scopeKey = "com.getnorthlight.daydream.store-wait.scope"
    private static let yieldKey = "com.getnorthlight.daydream.store-wait.yielded"
    private static let lettingKey = "com.getnorthlight.daydream.store-wait.letting-main-in"
    static var lettingMainIn: Bool { (Thread.current.threadDictionary[lettingKey] as? Bool) == true }
    static var current: Scope? { Thread.current.threadDictionary[scopeKey] as? Scope }
    /// Inside a `bounded` scope whose budget ran out: a read that failed just now may be only that (the history held a
    /// moment by another connection), so what it would have refreshed can stay as it was.
    public static var heldUpNow: Bool { current?.heldUp == true }
    static func noteYield() { Thread.current.threadDictionary[yieldKey] = true }
    /// `body`, where this thread waits at most `seconds` in all for another connection's lock (the store's own lock is
    /// not counted; `StoreLock` bounds that). `heldUp`: a statement gave up because the budget ran out, so an error the
    /// body threw may be only that (the caller can try the same work again later). A scope inside another keeps the
    /// smaller budget.
    public static func bounded<T>(_ seconds: TimeInterval, _ body: () throws -> T) -> (result: Result<T, Error>, heldUp: Bool) {
        let outer = current
        let scope = Scope(max(0, seconds * 1000))
        if let outer { scope.remainingMs = min(scope.remainingMs, outer.remainingMs) }
        Thread.current.threadDictionary[scopeKey] = scope
        let result = Result { try body() }
        if let outer {
            outer.remainingMs = min(outer.remainingMs, scope.remainingMs)
            if scope.heldUp { outer.heldUp = true }
            Thread.current.threadDictionary[scopeKey] = outer
        } else {
            Thread.current.threadDictionary.removeObject(forKey: scopeKey)
        }
        return (result, scope.heldUp)
    }
    /// Background work that can simply run again (a read, or one whole transaction): while it waits in SQLite for
    /// another connection and the main thread comes for the store's lock, it gives up and lets the main thread in, then
    /// runs again. It fails as before (busy) once another connection has held the history for `patience` in all.
    public static func lettingMainIn<T>(patience: TimeInterval = 1.5, _ body: () throws -> T) throws -> T {
        if Thread.isMainThread { return try body() }
        let start = Date()
        while true {
            let outer = Thread.current.threadDictionary[lettingKey]
            Thread.current.threadDictionary[lettingKey] = true
            Thread.current.threadDictionary.removeObject(forKey: yieldKey)
            defer { Thread.current.threadDictionary[lettingKey] = outer }
            do { return try body() }
            catch {
                let yielded = (Thread.current.threadDictionary[yieldKey] as? Bool) == true
                Thread.current.threadDictionary.removeObject(forKey: yieldKey)
                guard yielded, Date().timeIntervalSince(start) < patience else { throw error }
                usleep(5_000)
            }
        }
    }
}
