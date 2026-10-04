import Foundation

/// Main-window surface: only indexingLine is user-facing here. Detailed backend
/// names/reasons belong exclusively in Advanced > Search index.
public struct SearchLaunchSnapshot: Codable, Equatable {
    public enum Phase: String, Codable { case notStarted, checking, indexing, ready, fallback, stopped }
    public let phase: Phase
    public let advancedReason: String
    public var indexingLine: String? { phase == .indexing ? "Indexing…" : nil }
    public var canShowResults: Bool { phase != .checking && phase != .notStarted }
}

/// Concrete synthetic launch binding, not an unimplemented callback. Production
/// personal runtime provisioning is deliberately NOT inferred from this preview.
/// Opening the window starts one bounded background attempt; no UI-thread wait.
public final class SyntheticSearchLaunch {
    public let preview: SyntheticTypesensePreview
    private let queue = DispatchQueue(label:"daydream.synthetic.search.launch",qos:.utility)
    private let lock = NSLock()
    private var generation = 0
    private var cancelled = false
    private var began = false
    private var value = SearchLaunchSnapshot(phase:.notStarted,advancedReason:"not_started")
    private var observer: ((SearchLaunchSnapshot) -> Void)?
    private var delivery: DispatchQueue = .main

    public init() throws { preview = try SyntheticTypesensePreview.prepare() }
    public var snapshot: SearchLaunchSnapshot { lock.lock(); defer {lock.unlock()}; return value }

    /// Returns immediately. Missing runtime/pin falls back immediately. Deadline
    /// defaults to 8s, clamped to 0.05...20s; only the owned child is cancelled.
    /// A repeated begin is a no-op, never a second server/index/credential set.
    @discardableResult public func begin(executable: URL?, expectedSHA256: String?,
        budget: TimeInterval = 8, callbackQueue: DispatchQueue = .main,
        onChange: @escaping (SearchLaunchSnapshot) -> Void) -> Bool {
        lock.lock()
        guard !began else {lock.unlock(); return false}
        began=true; generation += 1; let ticket=generation
        delivery=callbackQueue; observer=onChange
        lock.unlock()
        guard let executable, let expectedSHA256 else {
            publish(.fallback, reason:executable == nil ? "runtime_missing" : "runtime_pin_required",ticket:ticket)
            return true
        }
        publish(.checking, reason:"checking_local_index",ticket:ticket)
        let timeout=budget.isFinite ? max(0.05,min(20,budget)) : 8
        let deadline=Date().addingTimeInterval(timeout)
        DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+timeout) { [weak self] in
            self?.expire(ticket:ticket)
        }
        queue.async { [weak self] in
            guard let self else {return}
            do {
                try self.preview.activate(executable:executable,expectedSHA256:expectedSHA256,deadline:deadline,
                    cancelled:{self.isCancelled(ticket)},
                    indexing:{self.publish(.indexing,reason:"initial_index_building",ticket:ticket)})
                self.publish(.ready,reason:"verified_local_index",ticket:ticket)
            } catch {
                self.publish(.fallback,reason:"local_index_unavailable",ticket:ticket)
                self.preview.stop()
            }
        }
        return true
    }
    private func isCancelled(_ ticket: Int) -> Bool {
        lock.lock(); defer {lock.unlock()}; return cancelled || ticket != generation
    }
    private func expire(ticket: Int) {
        lock.lock()
        guard ticket==generation, !cancelled, [.checking,.indexing].contains(value.phase) else {lock.unlock();return}
        cancelled=true; value=SearchLaunchSnapshot(phase:.fallback,advancedReason:"launch_deadline_exceeded")
        let update=value; lock.unlock(); notify(update,ticket:ticket)
        // Activation sees cancellation at the next bounded HTTP/page boundary.
        // The fallback result gate does not wait for child cleanup.
    }
    private func publish(_ phase: SearchLaunchSnapshot.Phase, reason: String, ticket: Int) {
        lock.lock()
        guard ticket==generation, !cancelled else {lock.unlock();return}
        value=SearchLaunchSnapshot(phase:phase,advancedReason:reason)
        let update=value;lock.unlock();notify(update,ticket:ticket)
    }
    private func notify(_ update: SearchLaunchSnapshot, ticket: Int) {
        lock.lock();let target=delivery;lock.unlock()
        target.async { [weak self] in
            guard let self else {return}
            self.lock.lock()
            // Expiry/stop must suppress queued late ready/indexing notifications.
            let valid=ticket==self.generation && (!self.cancelled || update==self.value)
            let callback=self.observer;self.lock.unlock()
            if valid {callback?(update)}
        }
    }
    /// Existing source query, on a background queue. Before readiness or after
    /// failure it intentionally bypasses index HTTP, not repeated slow retries.
    public func search(_ query: MemorySearchQuery, completion: @escaping (Result<MemorySearchResult,Error>) -> Void) {
        lock.lock();let searchTicket=generation;lock.unlock()
        DispatchQueue.global(qos:.userInitiated).async { [self] in
            let current=snapshot
            guard current.phase != .stopped else {completion(.failure(SearchFailure.changed));return}
            let result=Result { () throws -> MemorySearchResult in
                if current.phase == .ready { return try preview.store.searchResult(query) }
                return try preview.store.fallbackSearch(query,now:Date(),status:"unavailable_fallback")
            }
            lock.lock();let stillCurrent=searchTicket==generation;lock.unlock()
            guard stillCurrent else {completion(.failure(SearchFailure.changed));return}
            if case .success(let found)=result, current.phase == .ready, found.backend != "typesense", found.status != "sqlite_continuation" {
                lock.lock();let ticket=generation;lock.unlock()
                publish(.fallback,reason:"local_index_unavailable",ticket:ticket)
            }
            completion(result)
        }
    }
    /// Nonblocking UI lifecycle. Stop cancels late readiness and queues only this
    /// session's shutdown. New preview/retry uses a new controller and new store.
    public func stop() {
        lock.lock();cancelled=true;began=true;generation += 1;let ticket=generation
        value=SearchLaunchSnapshot(phase:.stopped,advancedReason:"stopped")
        let update=value;lock.unlock();notify(update,ticket:ticket)
        queue.async { [preview] in preview.stop() }
    }
    deinit { queue.async { [preview] in preview.stop() } }
}
