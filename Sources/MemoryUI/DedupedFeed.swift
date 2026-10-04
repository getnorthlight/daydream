// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.

import Combine
import Foundation

/// perf-1002: a view's only subscription when its sources change far more often than what it shows. Any change
/// announced by `changes` (an `objectWillChange`, fired before the new value is stored) schedules one recompute on the
/// next main-loop turn, however many arrive in that turn; the feed publishes only when the computed value differs
/// from the last one. `refresh` recomputes on a timer too, for a value that changes with the clock alone. Used by the
/// menu bar label: observing the whole app model re-rendered the status item on every heartbeat, search line and key,
/// each a fenced update shared with the menu bar's host process.
@MainActor public final class DedupedFeed<Value: Equatable>: ObservableObject {
    public private(set) var current: Value?
    /// How many times the feed published (checks).
    public private(set) var publishes = 0
    /// How many recomputes ran (checks).
    public private(set) var computes = 0
    private let compute: () -> Value?
    private var pending = false
    private var subscriptions: [AnyCancellable] = []
    private var timer: Timer?

    public init(changes: [AnyPublisher<Void, Never>], refresh: TimeInterval? = nil, compute: @escaping () -> Value?) {
        self.compute = compute
        current = compute()
        for change in changes { subscriptions.append(change.sink { [weak self] in self?.changed() }) }
        if let refresh {
            // A feed that is gone stops its own timer.
            let timer = Timer(timeInterval: refresh, repeats: true) { [weak self] t in
                MainActor.assumeIsolated { if let self { self.recompute() } else { t.invalidate() } }
            }
            timer.tolerance = refresh / 10
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }
    /// One recompute per main-loop turn, after the announced values are stored.
    public func changed() {
        guard !pending else { return }
        pending = true
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.recompute() } }
    }
    public func recompute() {
        pending = false
        computes += 1
        guard let next = compute(), next != current else { return }
        current = next
        publishes += 1
        objectWillChange.send()
    }
    public func stop() { timer?.invalidate(); timer = nil; subscriptions.removeAll() }
}
