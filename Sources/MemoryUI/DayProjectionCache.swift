import Foundation
import MemoryCore

// fix/day-nav (owner 10/3: Back/Next Day felt laggy). A day's page is drawn from its projection (`TodaySnapshot`),
// built from the day cache's read. Building it ran on the main thread inside the click; now:
//
// - The header moves on the click (it reads `browser.focusedDay` only); the day's page follows.
// - Projections are built off the main thread (`project`) and the last few are kept (`DayProjectionCache`, an LRU of
//   `capacity` days), so a day seen moments ago, or prefetched, swaps in on the click with no work at all.
// - After a past day shows, its previous and next recorded days (`FocusDay.step`) are read and projected in the
//   background (`DayNavigation.neighbours`).
// - Rapid clicks coalesce (`DayNavigation.settleDelay`): only the day the clicks stop on is read and projected.
// - A day not projected yet shows its header and a skeleton of its sections, sized from the cached counts
//   (`DayNavigation.skeletonRows`), then fades in (0.15 s; none with Reduce Motion).
//
// A projection belongs to one read of its day (`Stamp.loadedAt`) and one summaries state: a newer read, a summaries
// change or an invalidation (Forget, exclusions, a note written) makes it stale, and it is never shown again.

/// What a projection was built from: the day's read and the summaries state.
public struct DayProjectionStamp: Equatable, Sendable {
    public let loadedAt: Date?
    public let summaries: SummaryAvailability
    public let bundleNames: Int
    public init(loadedAt: Date?, summaries: SummaryAvailability, bundleNames: Int) {
        self.loadedAt = loadedAt; self.summaries = summaries; self.bundleNames = bundleNames
    }
}

/// The last few projected past days, least recently used first out.
@MainActor public final class DayProjectionCache {
    public static let capacity = 5
    public struct Entry {
        public let key: String
        public let day: ActionDay
        public let snapshot: TodaySnapshot
        public let stamp: DayProjectionStamp
    }
    private var entries: [String: Entry] = [:]
    /// Most recently used last.
    private(set) public var order: [String] = []

    public init() {}

    /// The day's projection when it was built from `stamp`; a stale one is dropped.
    public func projection(_ key: String, stamp: DayProjectionStamp) -> Entry? {
        guard let entry = entries[key] else { return nil }
        guard entry.stamp == stamp else { drop(key); return nil }
        touch(key)
        return entry
    }
    public func contains(_ key: String, stamp: DayProjectionStamp) -> Bool { entries[key]?.stamp == stamp }

    public func store(_ key: String, day: ActionDay, snapshot: TodaySnapshot, stamp: DayProjectionStamp) {
        entries[key] = Entry(key: key, day: day, snapshot: snapshot, stamp: stamp)
        touch(key)
        while order.count > Self.capacity { entries[order.removeFirst()] = nil }
    }

    /// nil drops every day (an invalidation of all days).
    public func drop(_ key: String?) {
        guard let key else { entries.removeAll(); order.removeAll(); return }
        entries[key] = nil
        order.removeAll { $0 == key }
    }

    private func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// Builds the day's projection off the main thread.
    public nonisolated static func project(day: ActionDay, summaries: SummaryAvailability, calendar: Calendar, now: Date,
                                           bundleNames: [String: String]) async -> TodaySnapshot {
        let box = DayProjectionInput(day: day, summaries: summaries, calendar: calendar, now: now, bundleNames: bundleNames)
        return await Task.detached(priority: .userInitiated) {
            TodaySnapshot.make(day: box.day, summaries: box.summaries, calendar: box.calendar, now: box.now,
                               bundleNames: box.bundleNames)
        }.value
    }
}

/// The projection's inputs, handed to the background task (plain values, read only).
private struct DayProjectionInput: @unchecked Sendable {
    let day: ActionDay
    let summaries: SummaryAvailability
    let calendar: Calendar
    let now: Date
    let bundleNames: [String: String]
}

/// Day-navigation rules (pure, checked headless).
public enum DayNavigation {
    /// Clicks closer together than this coalesce: the load waits this long and starts only if no newer click came.
    public static let rapidInterval: TimeInterval = 0.25
    /// How long a load waits after a rapid click before reading.
    public static let settleDelay: UInt64 = 90_000_000
    /// The page's fade-in when a day's content arrives.
    public static let fadeDuration: Double = 0.15
    /// Most placeholder rows a skeleton draws.
    public static let skeletonCap = 6

    /// The days worth projecting ahead of a click from `key`: its previous and next recorded days, never today
    /// (today is `browser.today`, always live), never `key` itself.
    public static func neighbours(of key: String, today: String, recorded: [String]?, calendar: Calendar) -> [String] {
        [-1, 1].compactMap { FocusDay.step(from: key, by: $0, today: today, recorded: recorded, calendar: calendar) }
            .filter { $0 != key && $0 != today }
    }

    /// Whether a click at `now` follows the previous one closely enough to coalesce.
    public static func isRapid(previous: Date?, now: Date) -> Bool {
        guard let previous else { return false }
        return now.timeIntervalSince(previous) < rapidInterval
    }

    /// Placeholder rows for a day not projected yet: its cached moment count, capped; 0 when unknown.
    public static func skeletonRows(momentCount: Int?) -> Int {
        max(0, min(momentCount ?? 0, skeletonCap))
    }
}
