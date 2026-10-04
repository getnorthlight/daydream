// DD-RECIPE: UI
//
// Pins the day data layer (plan §4.3/§4.4/§4.8, amendments F0b): TodaySnapshot and DayDigest from a
// real temp MemoryStore (ingested actions, a committed local note), the §3 summary gating on decoded
// ActionDay JSON, DaydreamDayCache (one retry on "Day changed", coalescing, TTL, invalidation,
// digests, one read for surfaces on appear and for a write's invalidate + force), TodayDigest
// (midnight 23:59→00:01 on a fixed clock, by notification, lazily, with todayKey moved mid-read and
// after a failed read; time-zone change), MomentResolver (search hit → moment, member-action
// paging), and the key router (never takes keys from text fields, input methods, sheets, other
// windows or when disabled; its monitor leaves with the window).
// Synthetic data only: a temp store under DD_CHECK_OUT, no app, no permissions, no capture.
import AppKit
import SwiftUI
import Combine
import MemoryCore
import MemoryUI

@MainActor @main enum DDTodayDataChecks {
    static var failures = 0
    static func check(_ ok: Bool, _ name: String, _ got: @autoclosure () -> String = "") {
        if ok { print("PASS " + name) } else {
            failures += 1
            print("FAIL: " + name + (got().isEmpty ? "" : " (got: " + got() + ")"))
        }
    }
    static func equal<T: Equatable>(_ got: T, _ want: T, _ name: String) { check(got == want, name, "\(got)") }

    static let zone = "America/Los_Angeles"
    static let la = TimeZone(identifier: zone)!
    static var cal: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = la; return c }
    static func d(_ day: Int, _ h: Int, _ m: Int, _ s: Int = 0) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: h, minute: m, second: s))!
    }
    /// The fixed clock every browser in this check reads.
    static var clock = d(22, 16, 24)
    static let root: URL = {
        let base = ProcessInfo.processInfo.environment["DD_CHECK_OUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("claude-dd-today-data-\(getpid())", isDirectory: true)
        return base.appendingPathComponent("stores", isDirectory: true)
    }()

    static func main() async {
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            FileHandle.standardError.write(Data("FAIL: dd-today-data watchdog expired\n".utf8)); exit(2)
        }
        setvbuf(stdout, nil, _IOLBF, 0)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.removeItem(at: root)
        do {
            try await storeSnapshot()
            try await reopenedSummary()
            try await fallbackStored()
            gating()
            await cacheRetry()
            await cacheLifecycle()
            await cacheSharing()
            try await resolver()
            try await rollover()
            await rolloverRaces()
            try await timeZoneChange()
            ownership()
            keyRouter()
        } catch {
            check(false, "check setup", "\(error)")
        }
        try? FileManager.default.removeItem(at: root)
        print(failures == 0 ? "PASS: dd-today-data: day cache, today snapshot, moment resolver and key router; synthetic temp stores only, no capture"
                            : "\(failures) dd-today-data check(s) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Helpers

    static func store(_ name: String) throws -> MemoryStore {
        let home = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        return try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    }
    static func ev(_ id: String, _ at: Date, _ app: String, _ bundle: String, _ title: String, url: String = "") -> Evidence {
        Evidence(id: id, at: iso(at), kind: "window.changed", app: app, bundle: bundle, title: title, url: url, synthetic: true)
    }
    /// A browser reading `source` on the fixed clock, counting reads per (day, cursor).
    final class Reads { var log: [(day: String, cursor: String?)] = [] }
    static func browser(_ source: MemoryStore, reads: Reads = Reads()) -> ActivityBrowser {
        let browser = ActivityBrowser(calendar: cal)
        browser.now = { clock }
        browser.loadCanonicalDay = { [weak browser] day, cursor in
            reads.log.append((day, cursor))
            let zone = browser?.calendar.timeZone.identifier ?? DDTodayDataChecks.zone
            return try source.dayLayers(day: day, timezone: zone, after: cursor, limit: 200, now: clock)
        }
        return browser
    }
    /// Lets main-actor tasks and main-queue work run until `condition` holds.
    static func wait(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while !condition() {
            if Date() > end { return false }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return true
    }
    static func commit(_ store: MemoryStore, kind: String, activity: String?, title: String, text: String) throws {
        let request = try store.prepareNote(kind: kind, day: "2026-09-22", timezone: zone, activityID: activity, now: clock)
        let output = NoteWriterOutput(requestID: request.id, title: title,
                                      bullets: [NoteBullet(text: text, actionIDs: request.actions.prefix(2).map(\.id), assertion: "observed")],
                                      generator: "local/synthetic", generatorVersion: "1")
        _ = try store.commitNote(output, now: clock)
    }

    // MARK: fix/expanded-summary: a saved note after the history is reopened

    /// A note the writer saved is still there after the history is closed and opened again (quit and reopen), and the
    /// open card still shows it: a one-bullet note that is the collapsed subtitle ("Email in Gmail") and a two-bullet
    /// one, each with Copy Summary in the bar. The first store is released before the second opens, read-only as the
    /// app's day reads are.
    static func reopenedSummary() async throws {
        clock = d(22, 16, 24)
        let home = root.appendingPathComponent("reopen", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let gmailTitle = "Inbox - Gmail", chatTitle = "Vision and delta"
        do {
            let writer = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
            for (i, m) in [0, 3, 6, 9].enumerated() {
                _ = try writer.ingest(ev("m\(i)", d(22, 11, m), "Google Chrome", "com.google.Chrome", gmailTitle, url: "https://mail.google.com"), now: clock)
                _ = try writer.ingest(ev("c\(i)", d(22, 14, m), "ChatGPT", "com.openai.chat", chatTitle), now: clock)
            }
            let layers = try writer.dayLayers(day: "2026-09-22", timezone: zone, limit: 200, now: clock)
            for m in layers.activities {
                let gmail = m.subject == gmailTitle
                let request = try writer.prepareNote(kind: "activity", day: "2026-09-22", timezone: zone, activityID: m.id, now: clock)
                let ids = request.actions.map(\.id)
                let bullets = gmail ? [NoteBullet(text: "Went through the Gmail inbox.", actionIDs: ids, assertion: "observed")]
                    : [NoteBullet(text: "Asked ChatGPT to clarify the product vision.", actionIDs: Array(ids.prefix(2)), assertion: "observed"),
                       NoteBullet(text: "Compared the delta between the two plans.", actionIDs: Array(ids.suffix(2)), assertion: "observed")]
                _ = try writer.commitNote(NoteWriterOutput(requestID: request.id, title: gmail ? "Email in Gmail" : "Clarifying vision and delta with ChatGPT",
                                                           bullets: bullets, generator: "local/synthetic", generatorVersion: "1"), now: clock)
            }
            equal(layers.activities.count, 2, "reopen: fixture has the Gmail and ChatGPT moments")
        }
        // Quit and reopen: a new store over the same history, nothing carried over in memory.
        let reopened = try MemoryStore(home: home)
        let browser = browser(reopened)
        browser.summaries = SummaryAvailability(provider: .local, busy: false)
        browser.today.refresh()
        check(await wait { (browser.today.snapshot?.moments.count ?? 0) == 2 }, "reopen: today's two moments read back from the reopened history")
        let moments = browser.today.snapshot?.moments ?? []
        guard let gmail = moments.first(where: { $0.title == "Email in Gmail" }),
              let chat = moments.first(where: { $0.title == "Clarifying vision and delta with ChatGPT" }) else {
            check(false, "reopen: both saved notes keep their titles", "\(moments.map(\.title))"); return
        }
        check(gmail.summary.isReady && chat.summary.isReady, "reopen: both saved notes read ready after reopening")
        equal(gmail.bullets.map(\.text), ["Went through the Gmail inbox."], "reopen: the one-bullet note's bullet is kept")
        equal(chat.bullets.count, 2, "reopen: the two-bullet note keeps both bullets")
        equal(MomentSubtitle.text(for: gmail), "Went through the Gmail inbox", "reopen: the Gmail row's collapsed subtitle is its one bullet")
        let caps = MomentActions.Capabilities(reopen: true, openApp: true, excludeApp: true, generate: true, delete: true, correct: true,
                                              summaries: browser.summaries, calendar: cal, now: clock)
        for m in [gmail, chat] {
            let bar = FocusListExpanded.barItems(MomentActions.items(for: m, context: .focusList, browser: caps), moment: m).map(\.title)
            check(FocusListExpanded.showsSummary(m) && FocusListExpanded.summaryStatus(for: m, provider: .local) == nil,
                  "reopen: the open card shows the saved Summary (\(m.title))")
            equal(bar, ["Copy Summary", "Forget This Moment…"], "reopen: the open card's bar has Copy Summary (\(m.title))")
        }
    }

    // MARK: fix/summary-fallback: code's fallback note through the real store

    /// Code's fallback note (every model answer failed) saved through the real store and read back after a reopen: its
    /// place-only line is the collapsed subtitle and the open card's Summary. Core keeps who wrote it: the fallback
    /// version only with code's fallback provider and the reverse, so neither side can be stored as the other. The model's
    /// same words stay filler.
    static func fallbackStored() async throws {
        clock = d(22, 16, 24)
        let home = root.appendingPathComponent("fallback", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let apps: [(app: String, bundle: String, title: String, hour: Int)] = [("TextEdit", "com.apple.TextEdit", "Untitled", 9),
                                                                              ("Terminal", "com.apple.Terminal", "qa - zsh", 11),
                                                                              ("Notes", "com.apple.Notes", "Notes", 13),
                                                                              ("Pages", "com.apple.iWork.Pages", "Draft", 15)]
        let fb = (gen: CodeFallbackNote.provider, ver: CodeFallbackNote.version), model = (gen: "local/qwen3.5-4b-q4_k_m", ver: "qwen35-4b-q4-b9723-prompt10-validator12")
        do {
            let writer = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
            for (i, a) in apps.enumerated() { for m in [0, 3, 6] { _ = try writer.ingest(ev("fb\(i)-\(m)", d(22, a.hour, m), a.app, a.bundle, a.title), now: clock) } }
            let layers = try writer.dayLayers(day: "2026-09-22", timezone: zone, limit: 200, now: clock)
            equal(layers.activities.count, 4, "fallback store: fixture has four moments")
            for m in layers.activities {
                let app = m.apps.first ?? ""
                let request = try writer.prepareNote(kind: "activity", day: "2026-09-22", timezone: zone, activityID: m.id, now: clock)
                let ids = request.actions.map(\.id)
                func out(_ pair: (gen: String, ver: String)) -> NoteWriterOutput {
                    NoteWriterOutput(requestID: request.id, title: app, bullets: [NoteBullet(text: "Typed a draft in \(app).", actionIDs: ids, assertion: "observed")],
                                     generator: pair.gen, generatorVersion: pair.ver)
                }
                // Split pairs: refused either way, nothing saved.
                for (pair, name) in [((fb.gen, model.ver), "code's provider, the model's version"), ((model.gen, fb.ver), "the model's provider, code's version"),
                                     ((fb.gen, "1"), "code's provider, another version"), (("code/moment-notes", fb.ver), "another code provider, the fallback version")] {
                    var refused = false
                    do { _ = try writer.commitNote(out(pair), now: clock) } catch { refused = true }
                    check(refused, "fallback store (\(app)): core refuses \(name)")
                }
                // Pages: the model's note with the same words; the rest: code's note.
                _ = try writer.commitNote(out(app == "Pages" ? model : fb), now: clock)
            }
        }
        let reopened = try MemoryStore(home: home)
        let saved = try reopened.dayLayers(day: "2026-09-22", timezone: zone, limit: 200, now: clock).activities
        for m in saved {
            let app = m.apps.first ?? "", out = m.generated?.output
            let want = app == "Pages" ? model : fb
            check(out?.generator == want.gen && out?.generatorVersion == want.ver,
                  "fallback store (\(app)): the saved note records \(app == "Pages" ? "the model" : "code") as its writer", "\(out?.generator ?? "-") \(out?.generatorVersion ?? "-")")
        }
        let browser = browser(reopened)
        browser.summaries = SummaryAvailability(provider: .local, busy: false)
        browser.today.refresh()
        check(await wait { (browser.today.snapshot?.moments.count ?? 0) == 4 }, "fallback store: the four moments read back after reopening")
        for m in browser.today.snapshot?.moments ?? [] {
            let app = m.apps.first ?? m.title
            if app == "Pages" {
                equal(m.bullets.map(\.text), [], "fallback store (Pages): the model's \"Typed a draft in Pages.\" is still filler")
                check(!FocusListExpanded.showsSummary(m), "fallback store (Pages): no Summary section for the model's filler")
            } else {
                equal(m.bullets.map(\.text), ["Typed a draft in \(app)."], "fallback store (\(app)): code's line shows")
                equal(MomentSubtitle.text(for: m), "Typed a draft in \(app)", "fallback store (\(app)): collapsed, code's line is the subtitle")
                check(FocusListExpanded.showsSummary(m) && FocusListExpanded.summaryStatus(for: m, provider: .local) == nil,
                      "fallback store (\(app)): expanded, the Summary section shows code's line")
            }
        }
    }

    // MARK: Real store → TodaySnapshot, DayDigest

    static func storeSnapshot() async throws {
        clock = d(22, 16, 24)
        let source = try store("today")
        let garden = "Garden sensor research", budget = "Quarterly budget review", logs = "Build logs triage"
        let evidence = [
            ev("g1", d(22, 9, 55), "Safari", "com.apple.Safari", garden, url: "https://example.org/sensors"),
            ev("g2", d(22, 10, 0), "TextEdit", "com.apple.TextEdit", garden),
            ev("g3", d(22, 10, 5), "Safari", "com.apple.Safari", garden, url: "https://example.org/sensors"),
            ev("g4", d(22, 10, 12), "TextEdit", "com.apple.TextEdit", garden),
            ev("b1", d(22, 13, 0), "Numbers", "com.apple.iWork.Numbers", budget),
            ev("b2", d(22, 13, 10), "Numbers", "com.apple.iWork.Numbers", budget),
            ev("b3", d(22, 13, 20), "Numbers", "com.apple.iWork.Numbers", budget),
            ev("l1", d(22, 15, 0), "Terminal", "com.apple.Terminal", logs),
            ev("l2", d(22, 15, 5), "Terminal", "com.apple.Terminal", logs),
            ev("y1", d(21, 20, 0), "Notes", "com.apple.Notes", "Evening reading list"),
        ]
        for e in evidence { _ = try source.ingest(e, now: clock) }
        let before = try source.dayLayers(day: "2026-09-22", timezone: zone, limit: 200, now: clock)
        guard let gardenNote = before.activities.first(where: { $0.subject == garden }) else { throw MemError.invalid("garden moment missing") }
        try commit(source, kind: "activity", activity: gardenNote.id, title: "Compared garden sensors", text: "Compared soil moisture sensors in Safari and TextEdit.")
        let layers = try source.dayLayers(day: "2026-09-22", timezone: zone, limit: 200, now: clock)
        equal(layers.activities.count, 3, "fixture: three moments today")

        let reads = Reads()
        let browser = browser(source, reads: reads)
        let today = browser.today
        check(today === browser.today && browser.dayCache === browser.dayCache, "browser.today and browser.dayCache are one shared instance each")
        check(today.snapshot == nil && reads.log.isEmpty, "TodayDigest is idle until the first refresh (no read on creation)")
        equal(browser.dayCache.todayKey, "2026-09-22", "todayKey follows the browser clock and calendar")
        today.refresh()
        check(await wait { today.snapshot != nil }, "refresh publishes today's snapshot")
        guard let snap = today.snapshot else { return }
        equal(snap.dayKey, "2026-09-22", "snapshot dayKey")
        equal(snap.momentCount, layers.activities.count, "snapshot momentCount == dayLayers activities")
        equal(snap.actionCount, layers.summary.actionCount, "snapshot actionCount == dayLayers actionCount")
        equal(snap.actionCount, 9, "snapshot counts the nine actions of today only")
        check(snap.countComplete && !snap.partial, "a small day is complete, not partial")
        equal(Set(snap.moments.map(\.id)), Set(layers.activities.map(\.id)), "snapshot moments are the day's activities")
        check(zip(snap.moments, snap.moments.dropFirst()).allSatisfy { $0.start <= $1.start }, "moments are chronological")
        equal(snap.loadedAt, clock, "loadedAt is the read time on the fixed clock")
        equal(reads.log.count, 1, "one read for the snapshot")
        let g = snap.moments.first { $0.subject == garden }, b = snap.moments.first { $0.subject == budget }, l = snap.moments.first { $0.subject == logs }
        check(g?.summary == .ready(generatedAt: clock, local: true), "committed local note reads ready and local", "\(String(describing: g?.summary))")
        equal(g?.title, "Compared garden sensors", "ready moment title is the note title")
        equal(g?.firstBullet, "Compared soil moisture sensors in Safari and TextEdit.", "ready moment first bullet")
        check(b?.summary == .summariesOff && l?.summary == .summariesOff, "summaries off: unsummarized moments are Off, never pending")
        equal(b?.title, budget, "an unsummarized moment is titled by its subject")
        check(snap.readyCount == 1 && snap.pendingCount == 0 && snap.tooLongCount == 0, "ready/pending/too-long counts with summaries off")
        check(snap.headline == nil && snap.headlineBullets.isEmpty, "no headline without a ready day note")
        // clusters → segments
        check(snap.moments.allSatisfy { moment in moment.clusters.count == layers.activities.first { $0.id == moment.id }?.clusters.count }, "every observation cluster becomes one segment")
        check(g.map { $0.start == d(22, 9, 55) && $0.end == d(22, 10, 12) && $0.clusters.first?.lowerBound == d(22, 9, 55) && $0.clusters.last?.upperBound == d(22, 10, 12) } ?? false,
              "segments span first to last observation")
        // topApps and latest
        equal(snap.topApps.first?.bundle, "com.apple.iWork.Numbers", "top app is the one with the most actions")
        check(snap.appsRankedByActions && zip(snap.topApps, snap.topApps.dropFirst()).allSatisfy { ($0.actions ?? 0) >= ($1.actions ?? 0) }, "topApps ranked by actions, descending")
        equal(snap.topApps.first?.name, "Numbers", "top app named from the loaded actions")
        equal(snap.appCount, 4, "four distinct apps today")
        equal(snap.latest?.id, l?.id, "latest is the moment that ended last")
        check(snap.firstObserved == d(22, 9, 55) && snap.lastObserved == d(22, 15, 5), "first and latest observation times")

        // Summary availability rebuilds without a read, keeping the read time.
        browser.summaries = SummaryAvailability(provider: .local, busy: false)
        check(await wait { today.snapshot?.pendingCount == 2 }, "summaries on this Mac: unsummarized moments turn pending")
        check(today.snapshot?.moments.first { $0.subject == budget }?.summary == .pending, "local provider: pending")
        equal(reads.log.count, 1, "a summaries change rebuilds without reading")
        equal(today.snapshot?.loadedAt, snap.loadedAt, "rebuild keeps the snapshot's read time")
        browser.summaries = SummaryAvailability(provider: .cloud, busy: false)
        check(await wait { today.snapshot?.summaries.provider == .cloud }, "cloud provider rebuild")
        check(today.snapshot?.moments.first { $0.subject == logs }?.summary == .pending, "cloud provider: pending")

        // DayDigest from the cache equals the builder over the same read.
        let digest = browser.dayCache.digests["2026-09-22"]
        equal(digest, DayDigest.make(day: layers, calendar: cal), "cache digest == DayDigest.make over the same day")
        check(digest?.momentCount == 3 && digest?.actionCount == 9 && digest?.complete == true, "digest counts")

        // A day note: generic title → no headline; a real title → headline. Invalidation refreshes today by itself.
        try commit(source, kind: "day", activity: nil, title: "Day summary", text: "Worked on sensors, budget and build logs.")
        browser.dayCache.invalidate("2026-09-22")
        check(await wait { browser.dayCache.cachedDay("2026-09-22")?.summary.status == "ready" }, "invalidating today rereads it (day note now ready)")
        try? await Task.sleep(nanoseconds: 30_000_000)
        equal(reads.log.count, 2, "today's refresh and the digest reload share one reread")
        // The snapshot before and after the reread look alike (no headline either way), so pin the builder on the reread day.
        let generic = browser.dayCache.cachedDay("2026-09-22")
        check(generic?.summary.status == "ready" && generic?.summary.generated?.output.title == "Day summary",
              "the reread day carries a ready day note titled \"Day summary\"", "\(String(describing: generic?.summary.status))")
        check(generic.map { TodaySnapshot.make(day: $0, summaries: browser.summaries, calendar: cal, now: clock).headline == nil } ?? false,
              "generic day title is never a headline (TodaySnapshot.make on the ready day)")
        check(today.snapshot?.dayKey == "2026-09-22" && today.snapshot?.headline == nil, "TodayDigest shows no headline for the generic day note")
        try commit(source, kind: "day", activity: nil, title: "Sensors, budget and build logs", text: "Worked on sensors, budget and build logs.")
        browser.dayCache.invalidate("2026-09-22")
        check(await wait { today.snapshot?.headline != nil }, "a ready, specific day note becomes the headline")
        equal(today.snapshot?.headline, "Sensors, budget and build logs", "headline text")
        check(today.snapshot?.headlineLocal == true && today.snapshot?.headlineBullets.first?.text == "Worked on sensors, budget and build logs.", "headline bullets and locality")

        // Digests: newest first, fresh days cost nothing, an empty day has no moments.
        let before21 = reads.log.count
        browser.dayCache.loadDigests(["2026-09-20", "2026-09-22", "2026-09-21"])
        check(await wait { browser.dayCache.digests["2026-09-20"] != nil }, "loadDigests fills every requested day")
        equal(reads.log.dropFirst(before21).map(\.day), ["2026-09-21", "2026-09-20"], "digests load newest first and skip today's fresh entry")
        check(browser.dayCache.digests["2026-09-21"].map { $0.momentCount == 1 && $0.actionCount == 1 } ?? false, "yesterday's digest")
        check(browser.dayCache.digests["2026-09-20"].map { $0.momentCount == 0 && $0.actionCount == 0 && $0.apps.isEmpty } ?? false, "an empty day's digest")
        let empty = try source.dayLayers(day: "2026-09-20", timezone: zone, limit: 200, now: clock)
        let emptySnap = TodaySnapshot.make(day: empty, summaries: SummaryAvailability(provider: .local, busy: false), calendar: cal, now: clock)
        check(emptySnap.moments.isEmpty && emptySnap.momentCount == 0 && emptySnap.latest == nil && emptySnap.topApps.isEmpty && emptySnap.firstObserved == nil,
              "0 actions: no moments, no segments, no latest, no apps")
    }

    // MARK: §3 gating on decoded JSON

    static func actionJSON(_ id: String, _ at: Date, app: String, bundle: String) -> [String: Any] {
        ["id": id, "evidenceIDs": [id], "at": iso(at), "kind": "window.changed", "app": app, "bundle": bundle, "site": "",
         "title": "t", "description": "d", "state": "observed", "revision": "r", "subject": "", "observationKey": id]
    }
    static func noteJSON(_ id: String, _ start: Date, _ end: Date, ids: [String], app: String, bundle: String, status: String) -> [String: Any] {
        ["id": id, "day": "2026-09-22", "timezone": zone, "subject": id, "actionIDs": ids, "apps": [app], "sites": [],
         "start": iso(start), "end": iso(end), "clusters": [["actionIDs": ids, "firstObservedAt": iso(start), "lastObservedAt": iso(end)]],
         "inputRevision": "r", "status": status, "bundles": [bundle], "bundleActionCounts": [bundle: ids.count]]
    }
    static func dayJSON(partial: Bool) throws -> ActionDay {
        let status = partial ? "incomplete" : "pending"
        let small = (0..<3).map { "s\($0)" }, long = (0..<442).map { "x\($0)" }
        let notes = [noteJSON("small", d(22, 9, 0), d(22, 9, 20), ids: small, app: "Zed", bundle: "dev.zed.Zed", status: status),
                     noteJSON("long", d(22, 11, 0), d(22, 14, 0), ids: long, app: "Safari", bundle: "com.apple.Safari", status: status)]
        let actions = [actionJSON("s0", d(22, 9, 0), app: "Zed", bundle: "dev.zed.Zed"), actionJSON("x0", d(22, 11, 0), app: "Safari", bundle: "com.apple.Safari")]
        let json: [String: Any] = [
            "summary": ["day": "2026-09-22", "timezone": zone, "start": iso(d(22, 0, 0)), "end": iso(d(23, 0, 0)), "activityIDs": ["small", "long"],
                        "actionCount": 445, "countIsComplete": !partial, "inputRevision": "r", "status": status],
            "activities": notes, "defaultLayer": "activities", "partial": partial,
            "actions": ["actions": actions, "revision": "r", "snapshot": ["epoch": "e", "highWater": 1], "candidates": actions.count]]
        return try JSONDecoder().decode(ActionDay.self, from: JSONSerialization.data(withJSONObject: json))
    }
    static func gating() {
        guard let whole = try? dayJSON(partial: false), let partial = try? dayJSON(partial: true) else { check(false, "gating fixture decodes"); return }
        let rows: [(String, ActionDay, SummaryAvailability.Provider, MomentSummaryState, MomentSummaryState, Int, Int)] = [
            ("off", whole, .off, .summariesOff, .tooLong, 0, 1),
            ("local", whole, .local, .pending, .tooLong, 1, 1),
            ("cloud", whole, .cloud, .pending, .tooLong, 1, 1),
            ("partial off", partial, .off, .incomplete, .incomplete, 0, 0),
            ("partial local", partial, .local, .incomplete, .incomplete, 0, 0),
            ("partial cloud", partial, .cloud, .incomplete, .incomplete, 0, 0),
        ]
        for (name, day, provider, small, long, pending, tooLong) in rows {
            let snap = TodaySnapshot.make(day: day, summaries: SummaryAvailability(provider: provider, busy: false), calendar: cal, now: clock)
            let s = snap.moments.first { $0.id == "small" }?.summary, l = snap.moments.first { $0.id == "long" }?.summary
            check(s == small && l == long && snap.pendingCount == pending && snap.tooLongCount == tooLong && snap.readyCount == 0,
                  "gating \(name): 3 actions → \(small), 442 actions → \(long); pending \(pending), too long \(tooLong)", "\(String(describing: s)) \(String(describing: l)) \(snap.pendingCount) \(snap.tooLongCount)")
            check(snap.headline == nil, "gating \(name): no headline without a ready day note")
        }
        let p = TodaySnapshot.make(day: partial, summaries: SummaryAvailability(provider: .local, busy: false), calendar: cal, now: clock)
        check(p.partial && !p.countComplete && p.actionCount == 445, "partial day: counts are lower bounds")
        let digest = DayDigest.make(day: partial, calendar: cal)
        check(!digest.complete && digest.momentCount == 2 && digest.actionCount == 445, "partial day digest is incomplete")
        equal(digest.topApp?.bundle, "com.apple.Safari", "digest ranks the 442-action app first")
    }

    // MARK: DaydreamDayCache: retry, coalescing, TTL, invalidation

    static func fixtureDay(_ key: String = "2026-09-22", actions: Int = 1) -> ActionDay {
        let ids = (0..<actions).map { "a\($0)" }
        let interval = try! DayScope.interval(day: key, timezone: zone)
        let json: [String: Any] = [
            "summary": ["day": key, "timezone": zone, "start": iso(interval.start), "end": iso(interval.end), "activityIDs": [],
                        "actionCount": actions, "countIsComplete": true, "inputRevision": "r", "status": "pending"],
            "activities": [], "defaultLayer": "activities", "partial": false,
            "actions": ["actions": ids.map { actionJSON($0, d(22, 9, 0), app: "Zed", bundle: "dev.zed.Zed") }, "revision": "r",
                        "snapshot": ["epoch": "e", "highWater": 1], "candidates": actions]]
        return try! JSONDecoder().decode(ActionDay.self, from: JSONSerialization.data(withJSONObject: json))
    }
    static func scripted(_ failures: [Error], delay: UInt64 = 0, calls: Reads) -> ActivityBrowser {
        let browser = ActivityBrowser(calendar: cal)
        browser.now = { clock }
        var remaining = failures
        browser.loadCanonicalDay = { day, cursor in
            calls.log.append((day, cursor))
            if delay > 0 { try await Task.sleep(nanoseconds: delay) }
            if !remaining.isEmpty { throw remaining.removeFirst() }
            return fixtureDay(day)
        }
        return browser
    }
    static func message(_ error: Error?) -> String { error.map { "\($0)" } ?? "none" }

    static func cacheRetry() async {
        clock = d(22, 16, 24)
        let dayChanged = MemError.invalid("Day changed; retry fresh read")
        do {
            let calls = Reads(), browser = scripted([dayChanged], calls: calls), cache = browser.dayCache
            let day = try? await cache.day("2026-09-22")
            check(day != nil && calls.log.count == 2, "one \"Day changed\" is retried once, then succeeds", "\(calls.log.count) reads")
            check(calls.log.allSatisfy { $0.cursor == nil }, "the retry is a fresh first-page read")
        }
        do {
            let calls = Reads(), browser = scripted([dayChanged, dayChanged, dayChanged], calls: calls), cache = browser.dayCache
            var thrown: Error?
            do { _ = try await cache.day("2026-09-22") } catch { thrown = error }
            check(message(thrown) == "Day changed; retry fresh read" && calls.log.count == 2, "a second \"Day changed\" surfaces: exactly one retry", "\(message(thrown)), \(calls.log.count) reads")
            check(cache.digests["2026-09-22"] == nil && cache.cachedDay("2026-09-22") == nil, "a failed read caches nothing")
        }
        do {
            let calls = Reads(), browser = scripted([MemError.database("disk I/O error")], calls: calls), cache = browser.dayCache
            var thrown: Error?
            do { _ = try await cache.day("2026-09-22") } catch { thrown = error }
            check(thrown != nil && calls.log.count == 1, "any other error surfaces without a retry", "\(calls.log.count) reads")
        }
        do {
            let calls = Reads(), browser = scripted([MemError.invalid("Actions changed; retry fresh read")], calls: calls)
            _ = try? await browser.dayCache.day("2026-09-22")
            equal(calls.log.count, 2, "\"Actions changed\" on a first-page read is retried once too")
        }
        do {
            let browser = ActivityBrowser(calendar: cal)
            var thrown: Error?
            do { _ = try await browser.dayCache.day("2026-09-22") } catch { thrown = error }
            check((thrown as? DaydreamDayCacheError) == .unavailable, "no canonical source: the cache reports unavailable")
            browser.today.refresh()
            try? await Task.sleep(nanoseconds: 50_000_000)
            check(browser.today.snapshot == nil && !browser.today.failed, "no canonical source: no snapshot and not a failure")
        }
        do {
            let calls = Reads(), browser = scripted(Array(repeating: MemError.database("locked"), count: 4), calls: calls)
            browser.today.refresh()
            check(await wait { browser.today.failed }, "a failing read marks TodayDigest failed")
            check(browser.today.snapshot == nil, "failed with no earlier snapshot shows nothing")
        }
    }

    static func cacheLifecycle() async {
        clock = d(22, 16, 24)
        let calls = Reads(), browser = scripted([], delay: 40_000_000, calls: calls), cache = browser.dayCache
        // Coalescing: concurrent reads of one day share one load.
        async let first = cache.day("2026-09-22")
        async let second = cache.day("2026-09-22")
        let both = try? await (first, second)
        check(both != nil && calls.log.count == 1, "concurrent reads of one day share one load", "\(calls.log.count) reads")
        // TTL for today.
        clock = d(22, 16, 24, 5)
        _ = try? await cache.day("2026-09-22")
        equal(calls.log.count, 1, "today's entry is reused inside todayMaxAge")
        clock = d(22, 16, 24, 11)
        _ = try? await cache.day("2026-09-22")
        equal(calls.log.count, 2, "today's entry is reread after todayMaxAge (10s)")
        _ = try? await cache.day("2026-09-22", force: true)
        equal(calls.log.count, 3, "force rereads a fresh entry")
        // A finished day is final until invalidated.
        _ = try? await cache.day("2026-09-21")
        clock = d(22, 18, 0)
        _ = try? await cache.day("2026-09-21")
        equal(calls.log.filter { $0.day == "2026-09-21" }.count, 1, "a day read after it ended stays cached")
        cache.invalidate("2026-09-21")
        check(cache.digests["2026-09-21"] != nil, "invalidate keeps the digest until the reread replaces it")
        check(await wait { calls.log.filter { $0.day == "2026-09-21" }.count == 2 }, "invalidate rereads a digested day in the background")
        _ = try? await cache.day("2026-09-21")
        equal(calls.log.filter { $0.day == "2026-09-21" }.count, 2, "the background reread refreshed the entry")
        // Invalidation during a read: the stale result is not stored.
        clock = d(22, 18, 0)
        let reading = Task { try await cache.day("2026-09-19") }
        try? await Task.sleep(nanoseconds: 10_000_000)
        cache.invalidate("2026-09-19")
        _ = try? await reading.value
        check(cache.cachedDay("2026-09-19") == nil, "a read that started before an invalidation is not cached")
        // invalidateAll drops every digest at once, then reloads them.
        let digested = Set(cache.digests.keys)
        cache.invalidateAll()
        check(cache.digests.isEmpty && cache.cachedDay("2026-09-22") == nil, "invalidateAll drops every entry and digest at once")
        check(await wait { Set(cache.digests.keys) == digested }, "invalidateAll reloads the digested days", "\(cache.digests.keys.sorted())")
        // At most 31 days stay cached, least recently used first out; today always stays.
        // Held: Sep 22 (today) and Sep 21, then Aug 1…31 (33 days): Sep 21 and Aug 1 leave; rereading Aug 1 pushes out Aug 2.
        check(cache.cachedDay("2026-09-22") != nil && cache.cachedDay("2026-09-21") != nil, "cache holds today and Sep 21 before the month")
        for day in 1...31 { _ = try? await cache.day(String(format: "2026-08-%02d", day)) }
        check(cache.cachedDay("2026-09-21") == nil && cache.cachedDay("2026-08-01") == nil, "past 31 days, the least recently used leave first")
        _ = try? await cache.day("2026-08-01")
        check(cache.cachedDay("2026-08-01") != nil && cache.cachedDay("2026-08-02") == nil && cache.cachedDay("2026-08-03") != nil,
              "rereading a day evicts the next least recently used")
        check(cache.cachedDay("2026-09-22") != nil, "today is never evicted")
        check(cache.digests["2026-09-21"] != nil, "an evicted day keeps its digest")
        // page(after:) is never cached and never retried.
        let pages = calls.log.count
        _ = try? await cache.page("2026-09-22", after: "cursor-1")
        _ = try? await cache.page("2026-09-22", after: "cursor-1")
        check(calls.log.count == pages + 2 && calls.log.last?.cursor == "cursor-1", "page(after:) always reads, with the cursor")
    }

    /// A browser whose Nth read returns a day with N actions, so the stored read can be told apart.
    static func counting(_ calls: Reads, delay: UInt64 = 60_000_000) -> ActivityBrowser {
        let browser = ActivityBrowser(calendar: cal)
        browser.now = { clock }
        browser.loadCanonicalDay = { day, cursor in
            calls.log.append((day, cursor))
            let n = calls.log.count
            try await Task.sleep(nanoseconds: delay)
            return fixtureDay(day, actions: n)
        }
        return browser
    }

    /// Reads are shared (data-audit: never read a day per view): surfaces asking on appear, callers during a slow
    /// read, and a write's invalidate + forced refresh each cost one read. A force nothing vouches for still rereads.
    static func cacheSharing() async {
        clock = d(22, 16, 24)
        do {
            let calls = Reads(), browser = counting(calls), today = browser.today
            for _ in 0..<4 { today.refreshIfStale() }
            check(await wait { today.snapshot != nil }, "4× refreshIfStale in one turn: the snapshot lands")
            try? await Task.sleep(nanoseconds: 80_000_000)
            equal(calls.log.count, 1, "4× refreshIfStale in one turn (surfaces on appear): exactly one read")
        }
        do {
            let calls = Reads(), browser = counting(calls), today = browser.today
            today.refresh(); today.refreshIfStale()
            check(await wait { today.snapshot != nil }, "refresh + refreshIfStale: the snapshot lands")
            try? await Task.sleep(nanoseconds: 80_000_000)
            equal(calls.log.count, 1, "refresh + refreshIfStale: one read")
        }
        do {
            // Another surface (the day chips) is reading today: refreshIfStale joins that read.
            let calls = Reads(), browser = counting(calls), today = browser.today
            browser.dayCache.loadDigests(["2026-09-22"])
            check(await wait { calls.log.count == 1 }, "harness: the digest read of today is in flight")
            today.refreshIfStale()
            check(await wait { today.snapshot != nil }, "refreshIfStale during another surface's read: the snapshot lands")
            try? await Task.sleep(nanoseconds: 80_000_000)
            equal(calls.log.count, 1, "refreshIfStale joins another surface's read of today in flight")
        }
        do {
            // A read slower than maxAge while callers keep asking: they join it, so it is never restarted and always lands.
            let calls = Reads(), browser = counting(calls, delay: 150_000_000), today = browser.today
            today.refreshIfStale()
            for step in 1...6 {
                try? await Task.sleep(nanoseconds: 20_000_000)
                clock = d(22, 16, 24, 4 * step)
                today.refreshIfStale()
            }
            check(await wait { today.snapshot != nil }, "a read slower than maxAge lands while callers keep asking")
            equal(calls.log.count, 1, "callers during a slow read join it: one read, never restarted")
            clock = d(22, 16, 24)
        }
        do {
            // A note write (F2): invalidate(day) + today.refresh(force: true). The invalidation's own reread serves the force.
            let calls = Reads(), browser = counting(calls), today = browser.today, cache = browser.dayCache
            today.refresh()
            check(await wait { today.snapshot != nil && cache.digests["2026-09-22"] != nil }, "writer sequence: first snapshot and digest")
            let base = calls.log.count
            cache.invalidate("2026-09-22"); today.refresh(force: true)
            check(await wait { today.snapshot?.actionCount == base + 1 }, "invalidate + force: the snapshot shows the reread", "\(String(describing: today.snapshot?.actionCount))")
            try? await Task.sleep(nanoseconds: 100_000_000)
            equal(calls.log.count - base, 1, "invalidate(today) + refresh(force: true): exactly one extra read")
            equal(cache.cachedDay("2026-09-22")?.summary.actionCount, base + 1, "the reread is stored")
            let all = calls.log.count
            cache.invalidateAll(); today.refresh(force: true)
            check(await wait { today.snapshot?.actionCount == all + 1 && cache.digests["2026-09-22"] != nil }, "invalidateAll + force: snapshot and digest reread")
            try? await Task.sleep(nanoseconds: 100_000_000)
            equal(calls.log.count - all, 1, "invalidateAll() + refresh(force: true): exactly one extra read")
        }
        do {
            // A force that no invalidation vouches for supersedes an ordinary read in flight; only the newer read is stored.
            let calls = Reads(), browser = counting(calls), cache = browser.dayCache
            let plain = Task { try await cache.day("2026-09-22") }
            check(await wait { calls.log.count == 1 }, "harness: an ordinary read is in flight")
            let forced = try? await cache.day("2026-09-22", force: true)
            _ = try? await plain.value
            equal(calls.log.count, 2, "force with no invalidation supersedes an ordinary read in flight")
            equal(forced?.summary.actionCount, 2, "the forced read returns its own read")
            equal(cache.cachedDay("2026-09-22")?.summary.actionCount, 2, "only the newer read is stored")
            // The vouch is spent by the first read after an invalidation: a later reread is ordinary again.
            cache.invalidate("2026-09-22")
            _ = try? await cache.day("2026-09-22")
            clock = d(22, 16, 24, 11)
            let ttl = Task { try await cache.day("2026-09-22") }
            check(await wait { calls.log.count == 4 }, "harness: today's TTL reread is in flight")
            _ = try? await cache.day("2026-09-22", force: true)
            _ = try? await ttl.value
            equal(calls.log.count, 5, "a TTL reread is not vouched: force supersedes it")
            clock = d(22, 16, 24)
        }
    }

    // MARK: MomentResolver

    static func resolver() async throws {
        clock = d(22, 16, 24)
        let source = try store("resolver")
        let title = "Sensor bench calibration"
        // 430 actions 20 s apart in one moment (09:00–11:23:00): over the writer's 400-action limit, and the member walk
        // needs three pages.
        for i in 0..<430 { _ = try source.ingest(ev(String(format: "k%03d", i), d(22, 9, 0).addingTimeInterval(Double(i) * 20), "Zed", "dev.zed.Zed", title), now: clock) }
        _ = try source.ingest(ev("n1", d(22, 12, 0), "Notes", "com.apple.Notes", "Shopping list draft"), now: clock)
        _ = try source.ingest(ev("n2", d(22, 12, 5), "Notes", "com.apple.Notes", "Shopping list draft"), now: clock)
        let layers = try source.dayLayers(day: "2026-09-22", timezone: zone, limit: 200, now: clock)
        guard let bench = layers.activities.first(where: { $0.subject == title }), let notes = layers.activities.first(where: { $0.subject != title }) else { throw MemError.invalid("resolver fixture") }
        equal(bench.actionIDs.count, 430, "resolver fixture: one 430-action moment")
        check(layers.actions.next != nil && layers.actions.actions.count == 200, "resolver fixture: the first page holds 200 actions")

        let reads = Reads(), browser = browser(source, reads: reads)
        let resolver = MomentResolver(cache: browser.dayCache, calendar: cal)
        let hit = notes.actionIDs[1]
        let found = await resolver.moment(containing: hit, at: d(22, 12, 5))
        equal(found?.id, notes.id, "a search hit resolves to the moment that contains it")
        equal(found?.dayKey, "2026-09-22", "resolved moment carries its day")
        check(found?.summary == .summariesOff && found?.actionCount == 2, "resolved moment carries §3 gating and counts")
        let benchHit = await resolver.moment(containing: bench.actionIDs[429], at: d(22, 11, 23, 0))
        equal(benchHit?.id, bench.id, "an action beyond the first page still resolves (moments cover the whole day)")
        equal(benchHit?.summary, .tooLong, "a 430-action moment is too long to summarize, whatever the provider")
        browser.summaries = SummaryAvailability(provider: .local, busy: false)
        let pending = await resolver.moment(containing: hit, at: d(22, 12, 5))
        equal(pending?.summary, .pending, "a resolved moment follows summary availability (local: pending)")
        let missing = await resolver.moment(containing: "no-such-action", at: d(22, 12, 0))
        check(missing == nil, "an unknown action resolves to nothing")
        let otherDay = await resolver.moment(containing: hit, at: d(21, 12, 0))
        check(otherDay == nil, "an action looked up on the wrong day resolves to nothing")
        equal(reads.log.filter { $0.day == "2026-09-22" }.count, 1, "resolving reuses the cached day")

        guard let slice = found, let big = benchHit else { return }
        let two = try await resolver.memberActions(of: slice, limit: 1)
        check(two.actions.map(\.id) == [notes.actionIDs[0]] && !two.complete, "limit 1 of 2: one member, incomplete")
        let all = try await resolver.memberActions(of: slice, limit: 10)
        check(all.actions.map(\.id) == notes.actionIDs && all.complete, "all members in time order, complete")
        let before = reads.log.count
        let paged = try await resolver.memberActions(of: big, limit: 500)
        check(paged.actions.count == 430 && paged.complete && paged.actions.map(\.id) == bench.actionIDs, "member walk pages past the first 200 actions")
        check(reads.log.dropFirst(before).contains { $0.cursor != nil }, "member walk uses cursor pages")
        let few = try await resolver.memberActions(of: big, limit: 5)
        check(few.actions.count == 5 && !few.complete, "a small limit stops early")

        // A stale cursor restarts once from a fresh first page.
        let stale = Reads(), flaky = ActivityBrowser(calendar: cal)
        flaky.now = { clock }
        var staleOnce = true
        flaky.loadCanonicalDay = { day, cursor in
            stale.log.append((day, cursor))
            if cursor != nil && staleOnce { staleOnce = false; throw MemError.invalid("Stale or invalid action cursor; restart pagination") }
            return try source.dayLayers(day: day, timezone: zone, after: cursor, limit: 200, now: clock)
        }
        let restarted = try await MomentResolver(cache: flaky.dayCache, calendar: cal).memberActions(of: big, limit: 500)
        check(restarted.complete && restarted.actions.count == 430, "a stale cursor restarts the member walk once")
        equal(stale.log.filter { $0.cursor == nil }.count, 2, "the restart rereads the first page")
    }

    // MARK: Midnight on a fixed clock

    static func rollover() async throws {
        clock = d(22, 23, 59)
        let source = try store("rollover")
        _ = try source.ingest(ev("late1", d(22, 23, 40), "Safari", "com.apple.Safari", "Late night reading", url: "https://example.org/late"), now: clock)
        _ = try source.ingest(ev("late2", d(22, 23, 50), "Safari", "com.apple.Safari", "Late night reading", url: "https://example.org/late"), now: clock)

        // By notification.
        do {
            let browser = browser(source), today = browser.today
            today.refresh()
            check(await wait { today.snapshot?.dayKey == "2026-09-22" }, "23:59: today is Sep 22")
            equal(today.snapshot?.momentCount, 1, "23:59: one moment")
            var seen: [(key: String?, days: Set<String>, today: String?)] = []
            let watch = today.$snapshot.sink { snap in seen.append((snap?.dayKey, Set(snap?.moments.map(\.dayKey) ?? []), browser.dayCache.todayKey)) }
            _ = try source.ingest(ev("early1", d(23, 0, 0, 30), "Notes", "com.apple.Notes", "Morning plan"), now: d(23, 0, 1))
            clock = d(23, 0, 1)
            NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
            check(await wait { browser.dayCache.todayKey == "2026-09-23" }, "00:01 NSCalendarDayChanged: todayKey moves to Sep 23")
            check(await wait { today.snapshot?.dayKey == "2026-09-23" }, "00:01: today's snapshot is Sep 23")
            check(today.snapshot?.moments.map(\.subject) == ["Morning plan"] && today.snapshot?.actionCount == 1, "00:01: only Sep 23's data", "\(String(describing: today.snapshot?.moments.map(\.subject)))")
            check(seen.allSatisfy { entry in entry.key == nil || entry.days.allSatisfy { $0 == entry.key } }, "every published snapshot holds only its own day's moments")
            check(!seen.contains { $0.key == "2026-09-22" && $0.today == "2026-09-23" }, "yesterday's snapshot is never published once today moved")
            watch.cancel()
        }
        // Lazily, without the notification (asleep through midnight).
        do {
            clock = d(22, 23, 59)
            let reads = Reads(), browser = browser(source, reads: reads), today = browser.today
            today.refresh()
            check(await wait { today.snapshot?.dayKey == "2026-09-22" }, "lazy: 23:59 snapshot is Sep 22")
            clock = d(23, 0, 1)
            today.refreshIfStale()
            check(today.snapshot == nil, "lazy: at 00:01 yesterday's snapshot is dropped at once")
            equal(browser.dayCache.todayKey, "2026-09-23", "lazy: todayKey recomputed on refresh")
            check(await wait { today.snapshot?.dayKey == "2026-09-23" }, "lazy: then today's snapshot loads")
            check(today.snapshot?.moments.allSatisfy { $0.dayKey == "2026-09-23" } == true, "lazy: no Sep 22 moment under Sep 23")
            check(reads.log.contains { $0.day == "2026-09-23" }, "lazy: Sep 23 was read")
        }
    }

    /// Midnight races on the fixed clock: another surface moves todayKey during a read; a failed 23:59 read.
    static func rolloverRaces() async {
        do {
            // 23:59:59: Sep 22's read is in flight when a day chip syncs todayKey at 00:00:01 (no notification).
            clock = d(22, 23, 59, 59)
            let calls = Reads(), browser = scripted([], delay: 120_000_000, calls: calls), today = browser.today, cache = browser.dayCache
            var published: [(snapshot: String?, today: String?)] = []
            let watch = today.$snapshot.sink { published.append(($0?.dayKey, cache.todayKey)) }
            today.refresh()
            check(await wait { calls.log.count == 1 }, "harness: Sep 22's read is in flight at 23:59:59")
            clock = d(23, 0, 0, 1)
            cache.syncTodayKey()
            check(await wait { today.snapshot?.dayKey == "2026-09-23" }, "todayKey moved by another surface mid-read: Sep 23's snapshot loads")
            try? await Task.sleep(nanoseconds: 150_000_000)
            check(!published.contains { $0.snapshot == "2026-09-22" }, "the Sep 22 read that lands after todayKey moved is never published",
                  published.map { "(\($0.snapshot ?? "nil"), \($0.today ?? "nil"))" }.joined(separator: " "))
            equal(today.snapshot?.dayKey, "2026-09-23", "today stays Sep 23")
            watch.cancel()
        }
        do {
            // 23:59: today's read fails. 00:01: the new day starts unfailed while its first read is in flight.
            clock = d(22, 23, 59)
            let calls = Reads(), browser = scripted([MemError.database("locked")], delay: 80_000_000, calls: calls), today = browser.today
            today.refresh()
            check(await wait { today.failed }, "23:59: today's read fails")
            clock = d(23, 0, 1)
            NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
            check(await wait { browser.dayCache.todayKey == "2026-09-23" && calls.log.count == 2 }, "00:01: todayKey moves and Sep 23's read starts")
            check(!today.failed && today.snapshot == nil, "00:01: Sep 22's failure does not carry into Sep 23 while its first read is in flight",
                  "failed \(today.failed)")
            check(await wait { today.snapshot?.dayKey == "2026-09-23" } && !today.failed, "00:01: Sep 23 loads unfailed")
        }
        do {
            // A retry of the same day keeps its failure until a read lands.
            clock = d(22, 16, 24)
            let calls = Reads(), browser = scripted([MemError.database("locked")], delay: 60_000_000, calls: calls), today = browser.today
            today.refresh()
            check(await wait { today.failed }, "harness: today's read failed")
            today.refresh()
            check(today.failed, "a retry of the same day keeps \"failed\" until a read lands")
            check(await wait { !today.failed && today.snapshot != nil }, "the retry's successful read clears \"failed\"")
        }
    }

    static func timeZoneChange() async throws {
        clock = d(22, 23, 30)                       // 06:30 UTC on Sep 23
        let source = try store("zone")
        _ = try source.ingest(ev("z1", d(22, 23, 10), "Safari", "com.apple.Safari", "Evening research", url: "https://example.org/z"), now: clock)
        // 20:00 on Sep 21 in Los Angeles is 03:00 on Sep 22 in UTC: the day it belongs to moves with the zone.
        _ = try source.ingest(ev("z0", d(21, 20, 0), "Notes", "com.apple.Notes", "Reading list"), now: clock)
        let reads = Reads(), browser = browser(source, reads: reads), today = browser.today, cache = browser.dayCache
        today.refresh()
        check(await wait { today.snapshot?.dayKey == "2026-09-22" }, "Los Angeles 23:30: today is Sep 22")
        cache.loadDigests(["2026-09-21"])
        check(await wait { cache.digests["2026-09-21"] != nil }, "digest before the zone change")
        equal(cache.digests["2026-09-21"]?.momentCount, 1, "Los Angeles: Sep 21 holds the 20:00 moment")
        browser.calendar.timeZone = TimeZone(identifier: "UTC")!
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        check(await wait { cache.todayKey == "2026-09-23" }, "NSSystemTimeZoneDidChange: todayKey follows the browser's new zone")
        check(cache.digests["2026-09-21"] == nil || reads.log.filter({ $0.day == "2026-09-21" }).count == 2, "time-zone change: every digest is dropped for a reread")
        check(await wait { today.snapshot?.dayKey == "2026-09-23" }, "time-zone change: today's snapshot follows")
        check(await wait { reads.log.filter { $0.day == "2026-09-21" }.count == 2 && cache.digests["2026-09-21"] != nil }, "time-zone change: a finished day's digest is reread")
        equal(cache.digests["2026-09-21"]?.momentCount, 0, "UTC: Sep 21 no longer holds the moment")
        equal(today.snapshot?.moments.map(\.subject), ["Evening research"], "UTC: today (Sep 23) holds 23:10 Los Angeles")
    }

    /// The browser owns the cache and TodayDigest; neither keeps the browser alive.
    static func ownership() {
        weak var weakBrowser: ActivityBrowser?, weakCache: DaydreamDayCache?, weakToday: TodayDigest?
        do {
            let browser = ActivityBrowser(calendar: cal)
            weakToday = browser.today; weakCache = browser.dayCache; weakBrowser = browser
        }
        check(weakBrowser == nil && weakCache == nil && weakToday == nil, "cache and TodayDigest do not retain the browser")
    }

    // MARK: Key router

    final class RouterModel: ObservableObject {
        @Published var enabled = true
        var consume = true
        var seen: [DaydreamKey] = []
    }
    struct RouterProbe: View {
        @ObservedObject var model: RouterModel
        var body: some View {
            Color.clear.frame(width: 200, height: 120)
                .daydreamKeyRouter(enabled: model.enabled) { key in model.seen.append(key); return model.consume }
        }
    }
    final class ProbeWindow: NSWindow {
        var fakeSheet: NSWindow?
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { true }
        override var attachedSheet: NSWindow? { fakeSheet }
    }
    /// A focusable view that is not a text responder (the list itself, a button).
    final class Focusable: NSView { override var acceptsFirstResponder: Bool { true } }
    /// A non-text input client (e.g. a custom editor) mid-composition.
    final class Composer: NSView, NSTextInputClient {
        var composing = true
        override var acceptsFirstResponder: Bool { true }
        func insertText(_ string: Any, replacementRange: NSRange) {}
        func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {}
        func unmarkText() {}
        func selectedRange() -> NSRange { NSRange(location: 0, length: 0) }
        func markedRange() -> NSRange { composing ? NSRange(location: 0, length: 1) : NSRange(location: NSNotFound, length: 0) }
        func hasMarkedText() -> Bool { composing }
        func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? { nil }
        func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }
        func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect { .zero }
        func characterIndex(for point: NSPoint) -> Int { 0 }
    }

    static func keyRouter() {
        func tick() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        let model = RouterModel()
        let window = ProbeWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        let other = ProbeWindow(contentRect: NSRect(x: 0, y: 0, width: 120, height: 80), styleMask: [.borderless], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 420, height: 200))
        let host = NSHostingView(rootView: RouterProbe(model: model))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 120)
        let plain = Focusable(frame: NSRect(x: 200, y: 0, width: 40, height: 40))
        let field = NSTextField(frame: NSRect(x: 240, y: 0, width: 120, height: 24))
        let composer = Composer(frame: NSRect(x: 360, y: 0, width: 40, height: 40))
        [host, plain, field, composer].forEach(container.addSubview)
        window.contentView = container
        host.layoutSubtreeIfNeeded(); tick()
        window.makeFirstResponder(plain)

        func event(_ code: UInt16, _ characters: String, _ flags: NSEvent.ModifierFlags = [], in target: NSWindow? = nil) -> NSEvent {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                             windowNumber: (target ?? window).windowNumber, context: nil, characters: characters,
                             charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)!
        }
        let up = String(UnicodeScalar(UInt32(NSUpArrowFunctionKey))!), down = String(UnicodeScalar(UInt32(NSDownArrowFunctionKey))!)
        /// Sends through NSApp (where local monitors run) and returns the keys the router handled.
        func send(_ e: NSEvent) -> [DaydreamKey] {
            model.seen = []
            NSApp.sendEvent(e)
            return model.seen
        }
        check(event(126, up).window === window, "harness: key events resolve to the probe window")
        equal(send(event(126, up, [.numericPad, .function])), [.up], "↑ routes")
        equal(send(event(125, down, [.numericPad, .function])), [.down], "↓ routes")
        equal(send(event(36, "\r")), [.returnKey], "Return routes")
        equal(send(event(76, "\u{3}", [.numericPad])), [.returnKey], "keypad Enter routes as Return")
        equal(send(event(53, "\u{1b}")), [.escape], "Esc routes")
        equal(send(event(8, "c", .command)), [.copy], "⌘C routes as copy")
        equal(send(event(8, "с", .command)), [.copy], "⌘C by key position on a non-Latin layout")
        equal(send(event(8, "c", [.command, .shift])), [], "⇧⌘C is not the router's")
        equal(send(event(126, up, [.option, .numericPad, .function])), [], "⌥↑ is not the router's")
        equal(send(event(126, up, [.control, .numericPad, .function])), [], "⌃↑ is not the router's")
        equal(send(event(0, "a")), [], "letters are not the router's")

        // Consumption. AppKit runs local monitors in no fixed order and stops at the first that returns nil. A witness
        // monitor that runs after the router sees the router's `handle` call already made; add witnesses until one
        // does, then a handled key must never reach it, while declined and ignored keys reach every witness.
        final class Witness { var log: [(key: UInt16, afterRouter: Bool)] = []; var monitor: Any? }
        var witnesses: [Witness] = []
        var after: Witness?
        model.consume = false
        for _ in 0..<64 where after == nil {
            let witness = Witness()
            witness.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [unowned witness] e in
                witness.log.append((e.keyCode, !model.seen.isEmpty)); return e
            }
            witnesses.append(witness)
            witnesses.forEach { $0.log = [] }
            _ = send(event(126, up, [.numericPad, .function]))
            after = witnesses.first { $0.log.contains { $0.key == 126 && $0.afterRouter } }
        }
        check(after != nil, "harness: a key monitor ordered after the router", "\(witnesses.count) witnesses")
        witnesses.forEach { $0.log = [] }
        equal(send(event(126, up, [.numericPad, .function])), [.up], "handle sees ↑ and declines it")
        check(witnesses.allSatisfy { $0.log.map(\.key) == [126] }, "a declined key reaches every later handler")
        model.consume = true
        witnesses.forEach { $0.log = [] }
        equal(send(event(125, down, [.numericPad, .function])), [.down], "handle sees ↓ and takes it")
        check(after?.log.isEmpty == true && !witnesses.contains { $0.log.contains { $0.afterRouter } }, "a handled key is consumed: nothing after the router sees it")
        witnesses.forEach { $0.log = [] }
        _ = send(event(0, "a"))
        check(witnesses.allSatisfy { $0.log.map(\.key) == [0] }, "a key the router ignores passes through untouched")
        witnesses.forEach { if let monitor = $0.monitor { NSEvent.removeMonitor(monitor) } }

        // Never steal keys from typing, input methods, sheets, other windows, or when disabled.
        window.makeFirstResponder(field)
        check(window.firstResponder is NSText || window.firstResponder === field, "harness: the text field has focus", "\(String(describing: window.firstResponder))")
        equal(send(event(126, up, [.numericPad, .function])), [], "text field focus: ↑ stays with the field")
        equal(send(event(36, "\r")), [], "text field focus: Return stays with the field")
        equal(send(event(8, "c", .command)), [], "text field focus: ⌘C stays with the field")
        window.makeFirstResponder(composer)
        equal(send(event(36, "\r")), [], "input method composing: Return stays with the input method")
        composer.composing = false
        equal(send(event(36, "\r")), [.returnKey], "no marked text: Return routes again")
        window.makeFirstResponder(plain)
        window.fakeSheet = other
        equal(send(event(53, "\u{1b}")), [], "attached sheet: Esc stays with the sheet")
        window.fakeSheet = nil
        equal(send(event(53, "\u{1b}", in: other)), [], "another window's key is never routed")
        model.enabled = false; host.layoutSubtreeIfNeeded(); tick()
        equal(send(event(126, up, [.numericPad, .function])), [], "disabled: nothing routes")
        model.enabled = true; host.layoutSubtreeIfNeeded(); tick()
        equal(send(event(126, up, [.numericPad, .function])), [.up], "re-enabled: ↑ routes")
        // Leaving the window removes the monitor. Out of any window the router ignores keys either way, so move the same
        // view into a second key window: a monitor left behind would route one ↑ twice. `handle` declines here, since a
        // consumed key stops at the first monitor and would hide the second.
        model.consume = false
        window.contentView = NSView(); tick()
        equal(send(event(126, up, [.numericPad, .function])), [], "removed from the window: its keys are not routed")
        let second = ProbeWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        host.removeFromSuperview()
        second.contentView = host
        host.layoutSubtreeIfNeeded(); tick()
        second.makeFirstResponder(nil)
        check(event(126, up, in: second).window === second, "harness: key events resolve to the second window")
        equal(send(event(126, up, [.numericPad, .function], in: second)), [.up], "moved to another window: one ↑ routes once (the old monitor was removed)")
        second.contentView = NSView(); tick()
        equal(send(event(126, up, [.numericPad, .function], in: second)), [], "removed again: nothing routes")
        window.orderOut(nil); other.orderOut(nil); second.orderOut(nil)
    }
}
