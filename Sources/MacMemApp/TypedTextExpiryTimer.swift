import Foundation
import MemoryCore

/// Typed words past the kept period are deleted at launch and then every hour,
/// whether or not recording is on and whether or not a summary is pending.
/// `MemoryStore.writePending` keeps its own call to the same job. The app model
/// owns this timer (never the Coordinator, which only exists while capture
/// can run). Checks pass a fake `schedule`.
final class TypedTextExpiryTimer {
    static let interval: TimeInterval = 3600
    /// Starts a repeating call every `interval` seconds; returns its cancel.
    typealias Schedule = (TimeInterval, @escaping () -> Void) -> () -> Void
    static let runLoop: Schedule = { interval, work in
        let timer = Timer(timeInterval: interval, repeats: true) { _ in work() }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    private let store: MemoryStore
    private let now: () -> Date
    private var cancel: (() -> Void)?
    private(set) var runs = 0
    private(set) var lastReport: TypedExpiryReport?
    /// The last run failed (the store was busy or unreadable). The next run tries again.
    private(set) var lastFailed = false

    init(store: MemoryStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }
    /// Runs the job now, then every hour until `stop`.
    func start(schedule: Schedule = TypedTextExpiryTimer.runLoop) {
        stop()
        run()
        cancel = schedule(Self.interval) { [weak self] in self?.run() }
    }
    func run() {
        runs += 1
        // A Keychain that was locked at the last read is read again first,
        // so typing resumes after an unlock even if nothing else asks.
        _ = try? store.retryLockedTypedVault(now: now())
        do { lastReport = try store.expireTypedText(now: now()); lastFailed = false }
        catch { lastFailed = true }
    }
    func stop() { cancel?(); cancel = nil }
    deinit { cancel?() }
}

/// What the app does with typed text at launch, in this order:
/// 1. attach the typing keyring named by this store's `core_store_id`
///    (the Keychain at runtime; checks pass an in-memory key store);
/// 2. settle build 4 plain-text rows (decision 6: seal them with a ready key
///    and consent, otherwise delete the words; past the period, stub them);
/// 3. once, delete website rows an earlier owner build saved on a messaging
///    site while Messages and email is still off (owner build only; nothing
///    elsewhere; launch's preparation does it when it prepared the history);
/// 4. run expiry now and start the hourly timer.
/// Each step fails closed on its own: a failed attach leaves no vault (typed
/// words are then never written), and settle and expiry still run.
enum TypedTextLaunch {
    struct Outcome {
        var vault: TypedVaultState?
        var settled: Int?
        let timer: TypedTextExpiryTimer
        var websiteSettled: Int? = nil
    }
    static func wire(store: MemoryStore, keys: (String) -> TypedKeyStore, now: @escaping () -> Date = Date.init,
                     schedule: TypedTextExpiryTimer.Schedule = TypedTextExpiryTimer.runLoop) -> Outcome {
        var vault: TypedVaultState?
        if let id = try? store.coreStoreID() {
            vault = try? store.attachVault(TypedTextVault(keyStore: keys(id)), now: now())
        }
        let settled = try? store.settleLegacyTypedText(now: now())
        // After launch prepared the history (off the main thread, before the model), the settle was its work: done
        // there, or left for the next launch's preparation, never read here on the main thread (gold r2-store-perf).
        let websiteSettled = store.launchWork == .prepared ? nil : try? store.settleWebsiteTypingRows(now: now())
        let timer = TypedTextExpiryTimer(store: store, now: now)
        timer.start(schedule: schedule)
        return Outcome(vault: vault, settled: settled, timer: timer, websiteSettled: websiteSettled)
    }
}
