import Foundation
import Combine
import MemoryCore

// One read path for day data (plan §4.4). Every surface asks the cache for a day's first page
// (`browser.loadCanonicalDay`, limit 200) instead of reading in `body`, so the Focus List, the
// capsule popover, the menu bar and settings draw the same read. Today's entry refreshes after
// `todayMaxAge`; a day read two minutes after it ended is final until invalidated. Concurrent
// reads of a day share one load, and a forced read joins the first read started after the day's
// latest invalidation, so a write costs one reread. A read that races a write ("Day changed;
// retry fresh read") is retried once, never more, and any other failure surfaces to the caller.
// Day boundaries (midnight, a time-zone change) move `todayKey` and invalidate the old today, so
// no surface ever shows yesterday's read under today's key.

public enum DaydreamDayCacheError: Error, Equatable {
    /// No canonical day source (legacy/synthetic mode) or the browser is gone.
    case unavailable
}

/// Metadata of a stored note, never its words or evidence.
public struct NoteCommitScope: Hashable, Sendable {
    public let day: String, timezone: String
    public init(day: String, timezone: String) { self.day = day; self.timezone = timezone }
}

/// A different or unknown time zone cannot be mapped to the display's day keys safely.
public struct NoteCommitInvalidation: Equatable, Sendable {
    public let days: Set<String>?
    public let refreshToday: Bool
    public static func make(scopes: [NoteCommitScope]?, timezone: String, today: String?) -> Self {
        guard let scopes else { return Self(days: nil, refreshToday: true) }
        guard !scopes.isEmpty else { return Self(days: [], refreshToday: false) }
        var days = Set<String>()
        for scope in scopes {
            guard scope.timezone == timezone,
                  let interval = try? DayScope.interval(day: scope.day, timezone: scope.timezone),
                  (try? DayScope.key(interval.start, timezone: scope.timezone)) == scope.day else {
                return Self(days: nil, refreshToday: true)
            }
            days.insert(scope.day)
        }
        guard let today else { return Self(days: nil, refreshToday: true) }
        return Self(days: days, refreshToday: days.contains(today))
    }
}

@MainActor public final class DaydreamDayCache: ObservableObject {
    /// Totals per loaded day ("yyyy-MM-dd"), for day chips, week bars and app usage. A failed reload removes the day's digest.
    @Published public private(set) var digests: [String: DayDigest] = [:]
    /// Today's key from the browser's clock (`now`) and calendar time zone; moves at midnight and on a time-zone change.
    @Published public private(set) var todayKey: String?
    /// The days with any record (`browser.loadRecordedDays`), oldest first; nil until read, or when there is no such read.
    /// Previous/Next Day step between these (`FocusDay.step`), so they never land on an empty day.
    @Published public private(set) var recordedDays: [String]?
    /// Today's (and any unfinished day's) entry is reread when older than this.
    public var todayMaxAge: TimeInterval = 10
    /// Bundle ID → app name for bundles the loaded actions leave unnamed (installed apps, e.g. `LocalApp.catalog()`).
    public var bundleNames: [String: String] = [:]

    private weak var browser: ActivityBrowser?
    private struct Entry { let day: ActionDay; let loadedAt: Date; let final: Bool }
    /// A read belongs to the key's generation it started in; an invalidation makes it stale.
    private struct Stamp: Equatable { let all: Int; let key: Int }
    private var entries: [String: Entry] = [:]
    /// Least recently used days leave first once more than `capacity` are held; today always stays.
    private var uses: [String: Int] = [:]
    private var useCount = 0
    private static let capacity = 31
    private var generations: [String: Int] = [:]
    private var allGeneration = 0
    /// `invalidate(key)` calls per day; with `allGeneration` they name the day's latest invalidation.
    private var invalidations: [String: Int] = [:]
    /// The latest invalidation a read of the day has started after: only the first such read is vouched.
    private var firstReadAfter: [String: Stamp] = [:]
    /// A read in flight. `vouched`: the first read to start after the day's latest invalidation, so it reflects that change.
    private struct Load { let stamp: Stamp; let vouched: Bool; let task: Task<ActionDay, Error> }
    private var loads: [String: Load] = [:]
    private var digestQueue: [String] = []
    private var digestWorker: Task<Void, Never>?
    /// The day the digest worker is reading; an invalidation during that read queues it again.
    private var digestReading: String?
    private var recordedRead: Task<Void, Never>?
    private var recordedGeneration = 0
    private var observers: [AnyCancellable] = []
    /// A day is final once read this long after its end (the collector's last flush).
    private static let settle: TimeInterval = 120
    /// Day key invalidated, or nil for every day.
    let invalidated = PassthroughSubject<String?, Never>()
    /// Midnight or a time-zone change was handled (after `todayKey` moved).
    let boundary = PassthroughSubject<Void, Never>()
    /// fix/prompt-row: the day's memory itself changed (a Forget, a new policy such as typing turned off, an exclusion,
    /// a restore): `invalidate` and `invalidateAll`, never `notesChanged`. What was opened from it goes at once.
    let cleared = PassthroughSubject<String?, Never>()

    public init(browser: ActivityBrowser) {
        self.browser = browser
        let center = NotificationCenter.default
        // Handled on the next main-queue turn, after any observer that updates the browser's calendar.
        func observe(_ name: Notification.Name, zone: Bool) -> AnyCancellable {
            center.publisher(for: name).sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.crossedBoundary(zone: zone) } }
            }
        }
        observers = [observe(.NSCalendarDayChanged, zone: false), observe(.NSSystemTimeZoneDidChange, zone: true)]
        todayKey = currentKey()
    }

    /// The day's first page (limit 200). Cached, and concurrent reads of a day share one load. `force` skips the cached
    /// entry. It joins a read in flight only when that read is the first to start after the day's latest invalidation,
    /// so `invalidate` + `force` costs one read; otherwise it supersedes the older read, whose result is not stored.
    public func day(_ key: String, force: Bool = false) async throws -> ActionDay {
        try await fetch(key, force ? .force : .cached)
    }

    enum ReadMode {
        /// A fresh entry, else the read in flight, else a new read.
        case cached
        /// A vouched read in flight (it started after the day's latest invalidation), else a new read that supersedes.
        case force
        /// Always a new read that supersedes: the caller saw the day change after every read so far started.
        case fresh
    }

    func fetch(_ key: String, _ mode: ReadMode) async throws -> ActionDay {
        if mode == .cached, let entry = entries[key], fresh(entry) { touch(key); return entry.day }
        if let load = loads[key], load.stamp == stamp(key), mode == .cached || (mode == .force && load.vouched) {
            return try await load.task.value
        }
        if mode != .cached { generations[key, default: 0] += 1 }
        let stamp = stamp(key)
        let change = Stamp(all: allGeneration, key: invalidations[key, default: 0])
        let vouched = change != Stamp(all: 0, key: 0) && firstReadAfter[key] != change
        firstReadAfter[key] = change
        let task = Task<ActionDay, Error> {
            defer { if loads[key]?.stamp == stamp { loads[key] = nil } }
            let started = now()
            let day: ActionDay
            do { day = try await read(key, after: nil) }
            catch where Self.changed(error) { day = try await read(key, after: nil) }
            if self.stamp(key) == stamp { store(key, day, loadedAt: started) }
            return day
        }
        loads[key] = Load(stamp: stamp, vouched: vouched, task: task)
        return try await task.value
    }

    /// Another page of the day's actions (member-action paging). Never cached or retried: a change invalidates the cursor.
    public func page(_ key: String, after cursor: String) async throws -> ActionDay {
        try await read(key, after: cursor)
    }

    /// The cached first page, if any, without reading or checking its age.
    public func cachedDay(_ key: String) -> ActionDay? { entries[key]?.day }

    /// claude/day-review-1003 perf pass: a day's review changed (a clause saved): patched into its cached read, which keeps
    /// its age and stamp. Nothing is invalidated and nothing is read again.
    public func patchReview(_ key: String, _ review: DayReviewFacts) {
        guard let e = entries[key], e.day.levels != nil else { return }
        var day = e.day
        day.levels?.review = review
        entries[key] = Entry(day: day, loadedAt: e.loadedAt, final: e.final)
    }

    /// Loads digests one day at a time, newest first, in the background; days with a fresh entry cost nothing.
    public func loadDigests(_ keys: [String]) {
        for key in keys where !digestQueue.contains(key) { digestQueue.append(key) }
        digestQueue.sort(by: >)
        guard digestWorker == nil, !digestQueue.isEmpty else { return }
        digestWorker = Task(priority: .utility) {
            while !digestQueue.isEmpty {
                let key = digestQueue.removeFirst()
                digestReading = key
                do { _ = try await day(key) } catch { digests[key] = nil }
                digestReading = nil
            }
            digestWorker = nil
        }
    }

    /// Reads which days have records (one small read, off the main thread); a newer request supersedes an older one.
    /// Today is always a destination, so only a change to another day (a Forget, a restore, an exclusion, midnight)
    /// needs a reread.
    public func loadRecordedDays() {
        guard let load = browser?.loadRecordedDays else { recordedDays = nil; return }
        recordedGeneration += 1
        let ticket = recordedGeneration
        let zone = calendar.timeZone.identifier
        recordedRead?.cancel()
        recordedRead = Task {
            let days = try? await load(zone)
            guard ticket == recordedGeneration else { return }
            if recordedDays != days { recordedDays = days }
            recordedRead = nil
        }
    }

    /// The day changed (a note, correction or deletion): its next read is fresh. Its digest stays until the reread replaces it.
    public func invalidate(_ key: String) {
        generations[key, default: 0] += 1
        invalidations[key, default: 0] += 1
        entries[key] = nil; uses[key] = nil
        if digests[key] != nil || digestReading == key { loadDigests([key]) }
        if recordedDays != nil, key != todayKey { loadRecordedDays() }
        cleared.send(key)
        invalidated.send(key)
    }

    /// Everything changed (exclusions, retention, time zone). Digests go at once, so an excluded app never lingers in a chip.
    public func invalidateAll() {
        allGeneration += 1
        entries.removeAll(); uses.removeAll()
        let keys = Array(digests.keys) + (digestReading.map { [$0] } ?? [])
        digests.removeAll()
        loadDigests(keys)
        if recordedDays != nil { loadRecordedDays() }
        cleared.send(nil)
        invalidated.send(nil)
    }

    /// A note was saved (fix/day-card). The writer doesn't say for which day, so every cached day is reread when next
    /// shown; but a note changes no digest (counts and apps), so digests stay as they are and nothing blanks: the page
    /// keeps its snapshot until the reread replaces it (stale-while-updating).
    public func notesChanged() {
        allGeneration += 1
        entries.removeAll(); uses.removeAll()
        invalidated.send(nil)
    }

    /// Known note-only writes leave other days, digests and opened prompt contents intact.
    /// Actual memory/policy changes still use invalidate/invalidateAll and their cleared signal.
    public func notesChanged(days: Set<String>) {
        for key in days.sorted() {
            generations[key, default: 0] += 1
            invalidations[key, default: 0] += 1
            entries[key] = nil; uses[key] = nil
            invalidated.send(key)
        }
    }

    /// Recomputes `todayKey`. When it moved, the old today is invalidated: its read predates midnight.
    @discardableResult public func syncTodayKey() -> String? {
        let key = currentKey()
        guard key != todayKey else { return key }
        let old = todayKey
        todayKey = key
        if let old { invalidate(old) }
        return key
    }

    // MARK: Internals shared with TodayDigest and MomentResolver

    var summaries: SummaryAvailability { browser?.summaries ?? SummaryAvailability(provider: .off, busy: false) }
    var calendar: Calendar { browser?.calendar ?? .current }
    func now() -> Date { browser?.now() ?? Date() }
    func loadedAt(_ key: String) -> Date? { entries[key]?.loadedAt }
    /// A read of the day is in flight and its result will be stored (current generation).
    func reading(_ key: String) -> Bool { loads[key].map { $0.stamp == stamp(key) } ?? false }

    /// A read that raced a write; a fresh first-page read may succeed.
    nonisolated static func changed(_ error: Error) -> Bool {
        guard case MemError.invalid(let message) = error else { return false }
        return ["Day changed", "Actions changed", "Snapshot invalidated"].contains { message.hasPrefix($0) }
    }
    /// A paging failure that a restart from a fresh first page can recover.
    nonisolated static func restartable(_ error: Error) -> Bool {
        if changed(error) { return true }
        guard case MemError.invalid(let message) = error else { return false }
        return message.hasPrefix("Stale or invalid action cursor")
    }

    private func currentKey() -> String? {
        guard let browser else { return nil }
        return try? DayScope.key(browser.now(), timezone: browser.calendar.timeZone.identifier)
    }
    private func touch(_ key: String) { useCount += 1; uses[key] = useCount }
    private func stamp(_ key: String) -> Stamp { Stamp(all: allGeneration, key: generations[key, default: 0]) }
    private func fresh(_ entry: Entry) -> Bool { entry.final || now().timeIntervalSince(entry.loadedAt) < todayMaxAge }
    private func read(_ key: String, after cursor: String?) async throws -> ActionDay {
        guard let load = browser?.loadCanonicalDay else { throw DaydreamDayCacheError.unavailable }
        return try await load(key, cursor)
    }
    private func store(_ key: String, _ day: ActionDay, loadedAt: Date) {
        let final = timestamp(day.summary.end).map { loadedAt >= $0.addingTimeInterval(Self.settle) } ?? false
        entries[key] = Entry(day: day, loadedAt: loadedAt, final: final)
        touch(key)
        while entries.count > Self.capacity,
              let oldest = entries.keys.filter({ $0 != todayKey }).min(by: { uses[$0, default: 0] < uses[$1, default: 0] }) {
            entries[oldest] = nil; uses[oldest] = nil
        }
        let digest = DayDigest.make(day: day, calendar: calendar, bundleNames: bundleNames)
        if digests[key] != digest { digests[key] = digest }
    }
    private func crossedBoundary(zone: Bool) {
        syncTodayKey()
        if zone { invalidateAll() }
        boundary.send()
    }
}

/// Today's snapshot for the Focus List header, the capsule popover, the menu bar and settings (plan §4.4).
/// Idle until the first `refresh`; after that it follows invalidations of today, midnight and time-zone changes,
/// and rebuilds (without a read) when summary availability changes.
@MainActor public final class TodayDigest: ObservableObject {
    /// Always today's (`cache.todayKey`); cleared the moment the day turns, never yesterday's under today's key.
    @Published public private(set) var snapshot: TodaySnapshot?
    /// The last read of today failed. A snapshot of today from an earlier read may remain. A new day starts unfailed.
    @Published public private(set) var failed = false

    private weak var browser: ActivityBrowser?
    private let cache: DaydreamDayCache
    private var day: ActionDay?
    private var active = false, refreshing = false
    private var generation = 0
    /// The day the latest refresh is reading; nil once it landed. A refresh of today already running satisfies `refreshIfStale`.
    private var reading: String?
    /// The day `failed` belongs to.
    private var failedDay: String?
    private var observers: [AnyCancellable] = []

    public init(browser: ActivityBrowser, cache: DaydreamDayCache) {
        self.browser = browser; self.cache = cache
        observers = [
            // @Published delivers before the property changes: build from the delivered value. fix/day-card: only when
            // what the page draws changes (a download's progress ticks rebuild nothing until its line's words change).
            browser.$summaries.removeDuplicates { $0.drawn == $1.drawn }.dropFirst()
                .sink { [weak self] value in self?.rebuild(summaries: value) },
            // Today or every day changed; or the day shown or being read was invalidated because todayKey moved on
            // (any surface may call `syncTodayKey`): drop it and read the new today.
            cache.invalidated.sink { [weak self] key in
                guard let self, self.active,
                      key == nil || key == self.cache.todayKey || key == self.reading || key == self.snapshot?.dayKey else { return }
                self.refresh()
            },
            cache.boundary.sink { [weak self] in if let self, self.active { self.refresh() } },
            // fix/prompt-row: prompts dropped (typing off, a Forget) or newly opened: patched into the snapshot shown,
            // no rebuild.
            browser.momentPrompts.changed.sink { [weak self] key in
                guard let self, let snapshot = self.snapshot, key == nil || key == snapshot.dayKey else { return }
                self.applyPrompts()
            },
        ]
    }

    /// Reads today through the cache (`force` rereads). A snapshot or failure from another day is dropped at once.
    public func refresh(force: Bool = false) {
        guard !refreshing else { return }
        refreshing = true; defer { refreshing = false }
        active = true
        generation += 1
        let ticket = generation
        guard let key = cache.syncTodayKey() else {
            snapshot = nil; day = nil; failed = false; failedDay = nil; reading = nil
            return
        }
        if snapshot?.dayKey != key { snapshot = nil; day = nil }
        if failedDay != key { if failed { failed = false }; failedDay = nil }
        reading = key
        Task {
            defer { if ticket == generation { reading = nil } }
            let result: Result<ActionDay, Error>
            do { result = .success(try await cache.day(key, force: force)) } catch { result = .failure(error) }
            guard ticket == generation else { return }
            // The day turned during the read: never publish (or fail) it as today; read the new today instead.
            guard key == cache.todayKey else { refresh(); return }
            switch result {
            case .success(let read):
                day = read
                build(read, summaries: browser?.summaries ?? cache.summaries, loadedAt: cache.loadedAt(key) ?? cache.now())
                if failed { failed = false }
                failedDay = nil
                // fix/prompt-row: each read of today opens its asks again, off the main thread (typing turned off, a
                // Forget or the kept period ending shows at the next read); the snapshot is patched when they differ.
                if let moments = snapshot?.moments, let browser { browser.momentPrompts.reload(key, moments: moments) }
            case .failure(let error) where (error as? DaydreamDayCacheError) == .unavailable:
                // No canonical source (legacy mode): nothing to show, and nothing failed.
                snapshot = nil; day = nil; failed = false; failedDay = nil
            case .failure:
                if snapshot?.dayKey != key { snapshot = nil; day = nil }
                failed = true; failedDay = key
            }
        }
    }

    /// Refreshes when there is no snapshot of today, the last read failed, or the snapshot is older than `maxAge`.
    /// A refresh of today already running, or another surface's read of today (in flight, or finished within
    /// `maxAge`), is joined instead of starting another read, so callers on appear never starve each other.
    public func refreshIfStale(maxAge: TimeInterval = 10) {
        let key = cache.syncTodayKey(), now = cache.now()
        if let snapshot, snapshot.dayKey == key, !failed, now.timeIntervalSince(snapshot.loadedAt) < maxAge { return }
        guard let key else { refresh(); return }
        if reading == key { return }
        let reusable = cache.reading(key) || cache.loadedAt(key).map { now.timeIntervalSince($0) < maxAge } == true
        refresh(force: !reusable)
    }

    /// claude/day-review-1003 perf pass: a clause was saved for `key`. Today's hero card gets the day's new review from the
    /// store's cache (no day read, `browser.loadDayReview`), patched into the snapshot and the cached read; any other
    /// day, a day not cached, or no loader: that day is read again as before.
    public func reviewChanged(_ key: String) {
        guard active, let browser, let loader = browser.loadDayReview, snapshot?.dayKey == key, key == cache.todayKey else {
            cache.invalidate(key); return
        }
        let ticket = generation
        Task {
            let review = await loader(key)
            guard ticket == generation, let snapshot = self.snapshot, snapshot.dayKey == key else { return }
            guard let review else { cache.invalidate(key); return }
            cache.patchReview(key, review)
            day?.levels?.review = review
            if snapshot.review != review {
                var next = snapshot
                next.review = review
                self.snapshot = next
            }
        }
    }

    private func build(_ day: ActionDay, summaries: SummaryAvailability, loadedAt: Date) {
        let calendar = browser?.calendar ?? cache.calendar
        let made = TodaySnapshot.make(day: day, summaries: summaries, calendar: calendar, now: loadedAt, bundleNames: cache.bundleNames)
        let next = browser.map { made.withPrompts($0.momentPrompts.prompts(made.dayKey)) } ?? made
        if snapshot != next { snapshot = next }
    }
    /// fix/prompt-row: the prompts held for the snapshot's day, patched in (a copy of the moments, never a rebuild).
    private func applyPrompts() {
        guard let snapshot, let browser else { return }
        let next = snapshot.withPrompts(browser.momentPrompts.prompts(snapshot.dayKey))
        if next != snapshot { self.snapshot = next }
    }
    private func rebuild(summaries: SummaryAvailability) {
        guard let day, let snapshot, snapshot.dayKey == day.summary.day else { return }
        build(day, summaries: summaries, loadedAt: snapshot.loadedAt)
    }
}

/// Search hit → the moment that contains it, and a moment's member actions for details (plan §4.4).
@MainActor public final class MomentResolver {
    private let cache: DaydreamDayCache
    private let calendar: Calendar
    /// Per day: action ID → moment ID, valid while the day's input revision holds.
    private var indexes: [String: (revision: String, moments: [String: String])] = [:]

    public init(cache: DaydreamDayCache, calendar: Calendar) { self.cache = cache; self.calendar = calendar }

    /// The moment containing `actionID`, read from the day of `at` (in `calendar`'s time zone); nil when the day
    /// can't be read or no moment holds the action (e.g. beyond a partial day's scan). A partial day's slice is `.incomplete`.
    public func moment(containing actionID: String, at: Date) async -> MomentSlice? {
        guard let key = try? DayScope.key(at, timezone: calendar.timeZone.identifier),
              let day = try? await cache.day(key) else { return nil }
        let index: [String: String]
        if let cached = indexes[key], cached.revision == day.summary.inputRevision { index = cached.moments }
        else {
            var built = [String: String]()
            for note in day.activities { for id in note.actionIDs where built[id] == nil { built[id] = note.id } }
            indexes[key] = (day.summary.inputRevision, built)
            index = built
        }
        guard let noteID = index[actionID], let note = day.activities.first(where: { $0.id == noteID }) else { return nil }
        // The whole day's directory, as TodaySnapshot uses, so a moment names its apps the same way everywhere.
        let directory = DaydreamAppDirectory(actions: day.actions.actions, notes: day.activities, overrides: [:], catalog: cache.bundleNames)
        return MomentSlice.make(note: note, dayPartial: day.partial, summaries: cache.summaries,
                                pageActions: day.actions.actions, directory: directory, live: day.levels?.live?.moments[note.id])
    }

    /// Up to `limit` of the moment's member actions in time order, paging the day's actions from the cached first
    /// page until enough are found or the pages pass the moment's end. A page from a changed day restarts once from
    /// a fresh first page. `complete`: every member was found.
    public func memberActions(of moment: MomentSlice, limit: Int) async throws -> (actions: [CanonicalAction], complete: Bool) {
        let members = Set(moment.actionIDs)
        let wanted = min(max(limit, 0), members.count)
        do { return try await walk(moment, members: members, wanted: wanted, restart: false) }
        catch where DaydreamDayCache.restartable(error) { return try await walk(moment, members: members, wanted: wanted, restart: true) }
    }

    /// `restart`: the day changed after every read so far began, so the first page is a new read, never a joined one.
    private func walk(_ moment: MomentSlice, members: Set<String>, wanted: Int, restart: Bool) async throws -> (actions: [CanonicalAction], complete: Bool) {
        var found = [CanonicalAction]()
        guard wanted > 0 else { return (found, members.isEmpty) }
        var page = try await cache.fetch(moment.dayKey, restart ? .fresh : .cached).actions
        let revision = page.revision
        var seen = Set<String>()
        while true {
            for action in page.actions where members.contains(action.id) && seen.insert(action.id).inserted {
                found.append(action)
                if found.count == wanted { return (found, found.count == members.count) }
            }
            // Actions run in time order: a page past the moment's end holds no more members.
            if let last = page.actions.last.flatMap({ timestamp($0.at) }), last > moment.end { break }
            guard let cursor = page.next else { break }
            let next = try await cache.page(moment.dayKey, after: cursor).actions
            guard next.revision == revision else { throw MemError.invalid("Actions changed; retry fresh read") }
            page = next
        }
        return (found, found.count == members.count)
    }
}

private enum DaydreamBrowserKeys {
    static let cache = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
    static let today = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
}

extension ActivityBrowser {
    /// The shared day cache (plan §4.5), created on first use and owned by the browser.
    public var dayCache: DaydreamDayCache {
        if let cache = objc_getAssociatedObject(self, DaydreamBrowserKeys.cache) as? DaydreamDayCache { return cache }
        let cache = DaydreamDayCache(browser: self)
        objc_setAssociatedObject(self, DaydreamBrowserKeys.cache, cache, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return cache
    }
    /// Today's shared snapshot (plan §4.5), created on first use over `dayCache`.
    public var today: TodayDigest {
        if let today = objc_getAssociatedObject(self, DaydreamBrowserKeys.today) as? TodayDigest { return today }
        let today = TodayDigest(browser: self, cache: dayCache)
        objc_setAssociatedObject(self, DaydreamBrowserKeys.today, today, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return today
    }
}
