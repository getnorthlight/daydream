import Foundation
@testable import MemoryCore

/// perf2-1005 (owner laptop, public 0.1.4 on 10/04: "Input tap turned off by macOS (timeout)" seven times in an hour, each
/// after a main-thread stall of about a second). Headless, no tap, no key, no Keychain:
/// 1-4. `TapMainHandoff`: the tap thread's wait for the main thread is bounded. A free main thread handles every event in
///      order, exactly as `DispatchQueue.main.sync` did; a stalled one costs each tap callback at most the deadline, and
///      the events it couldn't reach are one gap, told to main before anything after it. BENCH lines compare the longest
///      tap callback against the old unbounded wait under the same stall.
/// 5.   `TypedTextVault.prefetch`: a seal whose day key is already in the item uses the read made ahead (off the main
///      thread) instead of reading the Keychain on the caller; a seal that writes, or any write since, reads at once.
@main enum TapHandoffChecks {
    static var checks = 0
    static func require(_ ok: Bool, _ reason: String, _ got: @autoclosure () -> String = "") {
        guard ok else { FileHandle.standardError.write(Data("FAIL: \(reason) \(got())\n".utf8)); exit(1) }
        checks += 1
        print("PASS \(reason)")
    }
    static func ms(_ seconds: Double) -> String { String(format: "%.0f ms", seconds * 1000) }

    /// Main-thread state the handled events touch (main only).
    static var handled: [Int] = []
    static var gaps: [(at: Int, missed: TapMainHandoff.Missed)] = []

    /// One "tap thread" delivering `count` events `spacing` apart (each event a key when `key(i)`), the main thread stalled
    /// `stall` seconds starting `stallAt` seconds in. `bounded` false: the old `DispatchQueue.main.sync` hand-off.
    /// Returns each callback's duration and the results returned to the tap thread.
    static func run(count: Int, spacing: Double, stall: Double, stallAt: Double, bounded: Bool,
                    handoff: TapMainHandoff = TapMainHandoff(), handleCost: Double = 0) -> (callbacks: [Double], results: [Int?]) {
        handled = []; gaps = []
        let lock = NSLock()
        var callbacks = [Double](), results = [Int?]()
        var finished = false
        let start = Date()
        if stall > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + stallAt) { Thread.sleep(forTimeInterval: stall) }
        }
        let tap = Thread {
            for i in 0..<count {
                let t0 = Date()
                let r: Int?
                if bounded {
                    r = handoff.deliver(key: i % 2 == 0, post: { DispatchQueue.main.async(execute: $0) }, handle: {
                        if handleCost > 0 { Thread.sleep(forTimeInterval: handleCost) }
                        handled.append(i); return i
                    }, gap: { missed in gaps.append((handled.count, missed)) })
                } else {
                    r = DispatchQueue.main.sync { handled.append(i); return i }
                }
                lock.lock(); callbacks.append(Date().timeIntervalSince(t0)); results.append(r); lock.unlock()
                let next = start.addingTimeInterval(Double(i + 1) * spacing)
                let wait = next.timeIntervalSinceNow
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            }
            lock.lock(); finished = true; lock.unlock()
        }
        tap.start()
        while true {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            lock.lock(); let done = finished; lock.unlock()
            if done { break }
        }
        // Main catches up with whatever the tap thread posted last.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        return (callbacks, results)
    }

    static func main() {
        // 1. A free main thread: every event handled, in order, its result back on the tap thread; nothing missed.
        var r = run(count: 200, spacing: 0.002, stall: 0, stallAt: 0, bounded: true)
        require(handled == Array(0..<200) && gaps.isEmpty, "a free main thread handles every event in the tap's order", "\(handled.count) handled, \(gaps.count) gaps")
        require(r.results == (0..<200).map { Optional($0) }, "each event's result reaches the tap thread (a key's hand-back work)")

        // 2. A 1.2 s stall mid-stream, 10 ms between events: the old hand-off holds a callback for the whole stall
        //    (macOS turns a tap off at about a second); the bounded one never longer than its deadline.
        let old = run(count: 150, spacing: 0.01, stall: 1.2, stallAt: 0.3, bounded: false)
        let oldMax = old.callbacks.max() ?? 0
        print("BENCH old main.sync hand-off, 1.2 s main stall: longest tap callback \(ms(oldMax))")
        require(oldMax > 1.0, "the old hand-off waits out the whole stall (the laptop's tap timeouts)", ms(oldMax))
        let handoff = TapMainHandoff()
        r = run(count: 150, spacing: 0.01, stall: 1.2, stallAt: 0.3, bounded: true, handoff: handoff)
        let newMax = r.callbacks.max() ?? 0
        print("BENCH bounded hand-off (deadline \(ms(TapMainHandoff.defaultDeadline))), 1.2 s main stall: longest tap callback \(ms(newMax)), handled \(handled.count) of 150, gaps \(gaps.count)")
        require(newMax < TapMainHandoff.defaultDeadline + 0.1, "no tap callback waits much past the deadline", ms(newMax))
        require(gaps.count == 1, "the events main couldn't reach are one gap", "\(gaps.count)")
        let missed = gaps[0].missed
        require(missed.events + handled.count == 150, "every event is handled or counted missed, never both", "\(missed.events) + \(handled.count)")
        let missedIDs = Set(0..<150).subtracting(handled)
        require(missed.keys == missedIDs.filter { $0 % 2 == 0 }.count, "the gap counts the key downs among them", "\(missed.keys)")
        require(handled == handled.sorted(), "handled events keep the tap's order")
        require(handled[..<gaps[0].at].allSatisfy { $0 < missedIDs.min()! } && handled[gaps[0].at...].allSatisfy { $0 > missedIDs.max()! },
                "main hears of the gap before any event after it, and after every event before it")
        require(r.results.filter { $0 == nil }.count == missed.events, "a missed event hands nothing back (its key is never read)")
        require(handoff.pendingMissedKeys == 0, "main took the gap: nothing pending")

        // 3. Main reaches an event just before the deadline and takes longer than it: the tap thread waits for it (it is
        //    handled, as before), never counting it missed.
        let race = TapMainHandoff(deadline: 0.15)
        handled = []; gaps = []
        var raceResult: Int?? = .none
        var raceDone = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { Thread.sleep(forTimeInterval: 0.12) }
        Thread {
            raceResult = race.deliver(key: true, post: { DispatchQueue.main.async(execute: $0) }, handle: {
                Thread.sleep(forTimeInterval: 0.2); handled.append(7); return 7
            }, gap: { m in gaps.append((handled.count, m)) })
            raceDone = true
        }.start()
        while !raceDone { RunLoop.main.run(until: Date().addingTimeInterval(0.005)) }
        require(raceResult == .some(7) && handled == [7] && gaps.isEmpty, "an event main already started is finished and handed back, not missed")

        // 4. A stall longer than macOS's tap timeout, events every 2 ms (a key-repeat burst): still bounded.
        r = run(count: 600, spacing: 0.002, stall: 2.0, stallAt: 0.1, bounded: true)
        let burstMax = r.callbacks.max() ?? 0
        print("BENCH bounded hand-off, 2 s stall, 600 events: longest tap callback \(ms(burstMax)), missed \(gaps.first?.missed.events ?? 0)")
        require(burstMax < TapMainHandoff.defaultDeadline + 0.1 && gaps.count == 1, "a 2 s stall under a key burst stays bounded, one gap", ms(burstMax))

        vaultChecks()
        print("PASS: tap-handoff \(checks) checks; synthetic events and an in-memory key store, no tap or Keychain")
    }

    /// 5. The typing key's read ahead.
    static func vaultChecks() {
        let keys = InMemoryTypedKeyStore()
        let vault = TypedTextVault(keyStore: keys)
        try? vault.bind(store: "store-a")
        _ = vault.refresh(hadWords: false)
        do { try vault.create() } catch { require(false, "the vault sets up", "\(error)") }
        let today = "2026-10-05"
        _ = try? vault.seal("fictional words", id: "u0", epoch: today)   // makes today's key (a write)
        var before = vault.keychainReads
        _ = try? vault.seal("more fictional words", id: "u1", epoch: today)
        require(vault.keychainReads == before + 1, "without a read ahead, a seal reads the Keychain on its caller (as before)")
        vault.prefetch(now: 1, async: false)
        before = vault.keychainReads
        let sealed = try? vault.seal("words after a pause", id: "u2", epoch: today)
        require(sealed != nil && vault.keychainReads == before, "with a fresh read ahead, a seal whose day key exists reads nothing", "\(vault.keychainReads - before) reads")
        require((try? vault.open(sealed!, id: "u2", epoch: today)) == "words after a pause", "what it sealed opens")
        before = vault.keychainReads
        _ = try? vault.seal("again", id: "u3", epoch: today)
        require(vault.keychainReads == before + 1, "a read ahead is used once")
        // A new day's key is a write: read at once, never from the read ahead.
        vault.prefetch(now: 20_000_000_000, async: false)
        before = vault.keychainReads
        _ = try? vault.seal("next day", id: "u4", epoch: "2026-10-06")
        require(vault.keychainReads == before + 1, "a seal that adds a day key reads the item at once")
        // Another vault (same item) forgets everything after the read ahead: this vault reads at once and finds it gone.
        let other = TypedTextVault(keyStore: keys)
        try? other.bind(store: "store-a"); _ = other.refresh(hadWords: true)
        vault.prefetch(now: 40_000_000_000, async: false)
        try? other.destroy()
        var refused = false
        do { _ = try vault.seal("after forget", id: "u5", epoch: today) } catch { refused = true }
        require(refused && keys.raw == nil, "after a Forget elsewhere the read ahead is never used and nothing is re-created", "refused=\(refused)")
        // A read ahead only while typing is ready, at most once per prefetchEvery.
        let idle = TypedTextVault(keyStore: InMemoryTypedKeyStore())
        idle.prefetch(now: 1, async: false)
        require(idle.keychainReads == 0, "no read ahead while typing isn't set up")
    }
}
