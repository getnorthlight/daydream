import Foundation
import Combine
import MemoryCore

// fix/prompt-row: what the person typed to an AI app, on that moment's timeline row, on this Mac only.
//
// The words come from `browser.loadMomentPrompts` (the app: `MemoryStore.momentPromptRows` on a reader connection,
// then `ownerMomentPrompts` in the app's own process, off the main thread) once per read of a day, never per row or
// per frame. They are held here per day and moment, in memory only, and patched into the day's snapshot
// (`TodaySnapshot.withPrompts`: a copy of the moments, no rebuild), so a row draws a String it already has.
//
// Dropped at once when the day's memory changes (`DaydreamDayCache.cleared`: a Forget, typing turned off, a new
// policy, an exclusion, a restore); every read of the day opens them again, so what typing off, the kept period or a
// Forget hides is gone by the next read at the latest. Nothing here is written anywhere, logged, indexed or sent: the
// MCP and CLI (`mac-mem`) don't link MemoryUI, and the writers and the cloud read the store, which this never writes.

@MainActor public final class MomentPromptCache {
    private weak var browser: ActivityBrowser?
    private var byDay: [String: [String: String]] = [:]
    /// Least recently loaded days leave first once more than `capacity` are held.
    private var order: [String] = []
    private static let capacity = 8
    /// A load belongs to its day's ticket; a newer load or a drop makes it stale (its result is never kept).
    private var tickets: [String: Int] = [:]
    private var allTicket = 0
    private var loads: [String: Task<Void, Never>] = [:]
    private var observers: [AnyCancellable] = []
    /// A day's prompts changed (nil: every day's): snapshots patch themselves.
    public let changed = PassthroughSubject<String?, Never>()

    init(browser: ActivityBrowser, cache: DaydreamDayCache) {
        self.browser = browser
        observers = [cache.cleared.sink { [weak self] key in self?.drop(key) }]
    }

    /// The prompts held for a day (moment ID → one line); empty when none are.
    public func prompts(_ day: String) -> [String: String] { byDay[day] ?? [:] }

    /// Opens the day's asks again (off the main thread, through `browser.loadMomentPrompts`) for these moments.
    /// A moment without a main app can't be in an AI app, so it isn't asked about. Sends `changed` when they differ.
    public func reload(_ day: String, moments: [MomentSlice]) {
        guard let loader = browser?.loadMomentPrompts else {
            if byDay[day] != nil { byDay[day] = nil; changed.send(day) }
            return
        }
        let requests = moments.compactMap { m -> MomentPromptRequest? in
            guard let bundle = m.primaryBundle ?? m.bundles.first, !m.actionIDs.isEmpty else { return nil }
            // claude/livefix-1004: a moment without a note (still going, or not written yet) shows its newest ask.
            // claude/int-017 (owner 10/06: "Asked 5 questions · latest “…”"): every moment shows its newest ask (no model
            // writes a moment, so a note's line no longer stands over it).
            return MomentPromptRequest(momentID: m.id, actionIDs: m.actionIDs, primaryBundle: bundle, site: m.sites.first,
                                       newestFirst: true)
        }
        tickets[day, default: 0] += 1
        let ticket = tickets[day]!, all = allTicket
        loads[day]?.cancel()
        loads[day] = Task { @MainActor [weak self] in
            let result = requests.isEmpty ? [:] : await loader(requests)
            guard let self, !Task.isCancelled, self.tickets[day] == ticket, self.allTicket == all else { return }
            self.loads[day] = nil
            self.keep(day, result)
        }
    }

    /// Waits for the day's load in flight, if any (checks and renders).
    public func settled(_ day: String) async { await loads[day]?.value }

    /// The day's memory changed: its prompts go now (nil: every day's), and a load in flight is not kept.
    func drop(_ key: String?) {
        if let key {
            tickets[key, default: 0] += 1
            loads[key]?.cancel(); loads[key] = nil
            guard byDay.removeValue(forKey: key) != nil else { return }
            order.removeAll { $0 == key }
        } else {
            allTicket += 1
            loads.values.forEach { $0.cancel() }; loads.removeAll()
            guard !byDay.isEmpty else { return }
            byDay.removeAll(); order.removeAll()
        }
        changed.send(key)
    }

    private func keep(_ day: String, _ result: [String: String]) {
        order.removeAll { $0 == day }
        if result.isEmpty {
            guard byDay.removeValue(forKey: day) != nil else { return }
        } else {
            order.append(day)
            guard byDay[day] != result else { return }
            byDay[day] = result
            while order.count > Self.capacity { byDay[order.removeFirst()] = nil }
        }
        changed.send(day)
    }
}

private enum MomentPromptKeys {
    static let cache = UnsafeRawPointer(UnsafeMutableRawPointer.allocate(byteCount: 1, alignment: 1))
}

extension ActivityBrowser {
    /// fix/prompt-row: the timeline's AI asks (created on first use, owned by the browser).
    public var momentPrompts: MomentPromptCache {
        if let cache = objc_getAssociatedObject(self, MomentPromptKeys.cache) as? MomentPromptCache { return cache }
        let cache = MomentPromptCache(browser: self, cache: dayCache)
        objc_setAssociatedObject(self, MomentPromptKeys.cache, cache, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return cache
    }
}
