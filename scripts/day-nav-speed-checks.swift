import Foundation
@testable import MemoryCore
@testable import MemoryUI

/// fix/day-nav (owner 10/3: Back/Next Day felt laggy). Headless: the projection LRU, the neighbour and coalescing
/// rules, source pins on the timeline's click path, and a benchmark of the main-thread work between a day click and
/// the state the page paints from (before: a synchronous `TodaySnapshot.make`; after: a kept projection's lookup).
/// Fictional fixture days; no app, window, store or defaults of the person.
@main @MainActor enum DayNavSpeedChecks {
    static var checks = 0
    static func require(_ ok: Bool, _ reason: String, _ got: @autoclosure () -> String = "") {
        guard ok else { FileHandle.standardError.write(Data("FAIL: \(reason) \(got())\n".utf8)); exit(1) }
        checks += 1
    }
    static func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
    static let zone = "America/Los_Angeles"
    static var cal: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: zone)!; return c }()
    static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()

    static func main() async {
        lru()
        rules()
        pins()
        await benchmark()
        print("PASS: day-nav-speed \(checks) checks; fictional fixtures, no windows")
    }

    // MARK: Fixture

    /// A busy fictional day: `moments` moments over 12 apps, `perMoment` actions each.
    static func day(_ key: String, moments: Int = 200, perMoment: Int = 15) -> ActionDay {
        let interval = try! DayScope.interval(day: key, timezone: zone)
        let apps = (0..<12).map { ("App \($0)", "dev.fixture.app\($0)") }
        var notes: [[String: Any]] = [], actions: [[String: Any]] = []
        for m in 0..<moments {
            let start = interval.start.addingTimeInterval(TimeInterval(7 * 3600 + m * 240))
            let end = start.addingTimeInterval(200)
            let (app, bundle) = apps[m % apps.count]
            let ids = (0..<perMoment).map { "a\(m)-\($0)" }
            for (i, id) in ids.enumerated() {
                actions.append(["id": id, "evidenceIDs": [id], "at": iso.string(from: start.addingTimeInterval(TimeInterval(i * 10))),
                                "kind": "window.changed", "app": app, "bundle": bundle, "site": "", "title": "Fixture \(m)",
                                "description": "d", "state": "observed", "revision": "r", "subject": "", "observationKey": id])
            }
            notes.append(["id": "m\(m)", "day": key, "timezone": zone, "subject": "Fixture moment \(m)", "actionIDs": ids,
                          "apps": [app], "sites": [], "start": iso.string(from: start), "end": iso.string(from: end),
                          "clusters": [["actionIDs": ids, "firstObservedAt": iso.string(from: start), "lastObservedAt": iso.string(from: end)]],
                          "inputRevision": "r", "status": "pending", "bundles": [bundle], "bundleActionCounts": [bundle: ids.count]])
        }
        let json: [String: Any] = [
            "summary": ["day": key, "timezone": zone, "start": iso.string(from: interval.start), "end": iso.string(from: interval.end),
                        "activityIDs": notes.map { $0["id"]! }, "actionCount": actions.count, "countIsComplete": true,
                        "inputRevision": "r", "status": "pending"],
            "activities": notes, "defaultLayer": "activities", "partial": false,
            "actions": ["actions": actions, "revision": "r", "snapshot": ["epoch": "e", "highWater": 1], "candidates": actions.count]]
        return try! JSONDecoder().decode(ActionDay.self, from: JSONSerialization.data(withJSONObject: json))
    }
    nonisolated static let summaries = SummaryAvailability(provider: .local, busy: false)
    static func stamp(_ t: TimeInterval, _ s: SummaryAvailability = summaries) -> DayProjectionStamp {
        DayProjectionStamp(loadedAt: Date(timeIntervalSince1970: t), summaries: s, bundleNames: 0)
    }

    // MARK: LRU

    static func lru() {
        let small = day("2026-09-20", moments: 3, perMoment: 2)
        let snap = TodaySnapshot.make(day: small, summaries: summaries, calendar: cal, now: Date(timeIntervalSince1970: 1))
        let cache = DayProjectionCache()
        require(DayProjectionCache.capacity == 5, "keeps about five projected days")
        let keys = (1...6).map { String(format: "2026-09-%02d", $0) }
        for k in keys { cache.store(k, day: small, snapshot: snap, stamp: stamp(1)) }
        require(cache.order == Array(keys.suffix(5)), "a sixth day evicts the least recently used", "\(cache.order)")
        require(cache.projection(keys[0], stamp: stamp(1)) == nil, "the evicted day is gone")
        require(cache.projection(keys[1], stamp: stamp(1)) != nil, "a kept day is returned")
        require(cache.order.last == keys[1], "a hit becomes most recently used")
        cache.store("2026-09-07", day: small, snapshot: snap, stamp: stamp(1))
        require(cache.projection(keys[2], stamp: stamp(1)) == nil && cache.projection(keys[1], stamp: stamp(1)) != nil,
                "after a hit, the next eviction takes the older day")
        require(cache.projection(keys[3], stamp: stamp(2)) == nil, "a newer read of the day: the projection is stale")
        require(cache.projection(keys[3], stamp: stamp(1)) == nil, "a stale projection is dropped, never shown again")
        let off = SummaryAvailability(provider: .off, busy: false)
        require(cache.projection(keys[4], stamp: stamp(1, off)) == nil, "a summaries change makes it stale")
        require(cache.contains(keys[5], stamp: stamp(1)), "contains")
        cache.drop(keys[5])
        require(!cache.contains(keys[5], stamp: stamp(1)), "an invalidated day is dropped")
        cache.drop(nil)
        require(cache.order.isEmpty, "an invalidation of every day drops all")
    }

    // MARK: Rules

    static func rules() {
        let recorded = ["2026-09-25", "2026-09-28", "2026-09-30", "2026-10-03"]
        let today = "2026-10-03"
        require(DayNavigation.neighbours(of: "2026-09-28", today: today, recorded: recorded, calendar: cal) == ["2026-09-25", "2026-09-30"],
                "neighbours: the previous and next recorded days")
        require(DayNavigation.neighbours(of: "2026-09-30", today: today, recorded: recorded, calendar: cal) == ["2026-09-28"],
                "today is never prefetched (it is always live)")
        require(DayNavigation.neighbours(of: today, today: today, recorded: recorded, calendar: cal) == ["2026-09-30"],
                "from today: the previous recorded day")
        require(DayNavigation.neighbours(of: "2026-09-25", today: today, recorded: recorded, calendar: cal) == ["2026-09-28"],
                "the first recorded day has no previous")
        require(DayNavigation.neighbours(of: "2026-09-28", today: today, recorded: nil, calendar: cal) == ["2026-09-27", "2026-09-29"],
                "recorded days unknown: calendar neighbours")
        let t0 = Date(timeIntervalSince1970: 1000)
        require(!DayNavigation.isRapid(previous: nil, now: t0), "a first click is not rapid")
        require(DayNavigation.isRapid(previous: t0, now: t0.addingTimeInterval(0.1)), "clicks 0.1 s apart coalesce")
        require(!DayNavigation.isRapid(previous: t0, now: t0.addingTimeInterval(0.6)), "clicks 0.6 s apart don't")
        require(DayNavigation.skeletonRows(momentCount: nil) == 0 && DayNavigation.skeletonRows(momentCount: 3) == 3
                && DayNavigation.skeletonRows(momentCount: 40) == DayNavigation.skeletonCap, "skeleton rows from the cached count, capped")
        require(DayNavigation.fadeDuration == 0.15, "0.15 s fade")
    }

    // MARK: Source pins

    static func pins() {
        let t = source("Sources/MemoryUI/CanonicalTimeline.swift")
        func body(_ start: String, _ end: String) -> String {
            guard let a = t.range(of: start), let b = t.range(of: end, range: a.upperBound..<t.endIndex) else { return "" }
            return String(t[a.lowerBound..<b.lowerBound])
        }
        let load = body("private func loadPast(", "/// What a projection of `key` is built from now")
        require(!load.isEmpty, "loadPast found")
        require(load.contains("} else if isStatic, !force, let cached = cache.cachedDay(key) {")
                && load.components(separatedBy: "setPast(").count == 2 && !load.contains("TodaySnapshot.make"),
                "no projection is built on the click path (still renders and checks only)")
        require(load.contains("box.projections.projection(key, stamp: projectionStamp(key))"), "a kept projection shows at once")
        require(load.contains("box.loadTask?.cancel()"), "a newer click cancels the load in flight")
        require(load.contains("if rapid && !shown { try? await Task.sleep(nanoseconds: DayNavigation.settleDelay) }")
                && load.contains("guard !Task.isCancelled, ticket == box.generation else { return }"), "rapid clicks: only the last day loads")
        require(load.contains("prefetchNeighbours(of: key)"), "a shown past day prefetches its neighbours")
        let project = body("private func projectPast(", "private func showPast(")
        require(project.contains("await DayProjectionCache.project("), "projections are built off the main thread")
        require(t.contains("if key == todayKey { today.refreshIfStale(); prefetchNeighbours(of: key) }"), "today prefetches yesterday")
        require(t.contains("box.projections.drop(key)\n            invalidated(key)"), "an invalidation drops the kept projection")
        require(t.contains(".transition(.asymmetric(insertion: .opacity, removal: .identity))")
                && t.contains(".animation(dayFade, value: FocusDayFace(key: key, loaded: snap != nil))"), "the day's content fades in")
        require(t.contains("private var dayFade: Animation? { reduceMotion || isStatic ? nil : .easeOut(duration: DayNavigation.fadeDuration) }"),
                "no fade with Reduce Motion")
        require(t.contains("FocusSummarySkeleton(rows: DayNavigation.skeletonRows(momentCount: cache.digests[key]?.momentCount))"),
                "an unloaded day shows a skeleton sized from its cached count")
        require(!t.contains("ProgressView()"), "no spinner on the day page")
        // The header reads only the focused day, so it moves on the click.
        require(t.contains("FocusListHeader(day: dayDate(key), dayKey: key"), "the header is drawn from the focused day key")
    }

    // MARK: Benchmark

    static func ms(_ seconds: Double) -> String { String(format: "%.3f ms", seconds * 1000) }
    static func median(_ xs: [Double]) -> Double { let s = xs.sorted(); return s[s.count / 2] }
    static func time(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9
    }

    static func benchmark() async {
        let key = "2026-09-28"
        let fixture = day(key)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let runs = 25
        var before: [Double] = [], after: [Double] = [], offMain: [Double] = []
        // Before: the click ran `setPast`, a full projection on the main thread.
        for _ in 0..<runs {
            before.append(time { _ = TodaySnapshot.make(day: fixture, summaries: summaries, calendar: cal, now: now).withPrompts([:]) })
        }
        // After: the day was prefetched; the click looks the projection up and patches its prompts.
        let cache = DayProjectionCache()
        let built = await DayProjectionCache.project(day: fixture, summaries: summaries, calendar: cal, now: now, bundleNames: [:])
        let same = TodaySnapshot.make(day: fixture, summaries: summaries, calendar: cal, now: now)
        require(built == same, "the off-main projection equals the main-thread one")
        cache.store(key, day: fixture, snapshot: built, stamp: stamp(1))
        for _ in 0..<runs {
            after.append(time { _ = cache.projection(key, stamp: stamp(1))?.snapshot.withPrompts([:]) })
        }
        // Not prefetched: the projection runs off the main thread (the header and skeleton paint meanwhile).
        for _ in 0..<5 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = await DayProjectionCache.project(day: fixture, summaries: summaries, calendar: cal, now: now, bundleNames: [:])
            offMain.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9)
        }
        // Unchanged by this fix: the day cache's digest of a read, on the main thread when a read lands (never on a kept day's click).
        let digest = median((0..<5).map { _ in time { _ = DayDigest.make(day: fixture, calendar: cal) } })
        let b = median(before), a = median(after)
        print("BENCH day-nav (200 moments, 3000 actions, median of \(runs)): click main-thread work before \(ms(b)), after \(ms(a)) (prefetched); off-main projection \(ms(median(offMain))) when not prefetched; digest on read landing \(ms(digest))")
        require(a < b, "a prefetched day's click does less main-thread work", "\(ms(a)) vs \(ms(b))")
    }
}
