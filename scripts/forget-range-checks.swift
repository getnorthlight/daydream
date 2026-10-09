import Foundation
import Darwin
@testable import MemoryCore
import MemoryUI

/// Forget a time range, the search index side: after a range commit the next index sync removes every forgotten
/// action's document and its ledger row, and keeps the rest. A fake Typesense in memory; a synthetic store only.
/// (The store side lives in Checks/ForgetRangeChecks.swift, run by MacMemChecks.) Then the sheet's words and its model
/// (what was forget-range-render, without the renders) against a synthetic store: no window, no app, no permission.
private final class FakeIndex: TypesenseTransport {
    var docs = [String: SearchDocument](); var exists = false
    func request(_ method: String, _ path: String, query: [URLQueryItem], body: Data?, deadline: Date) throws -> TypesenseResponse {
        func response(_ status: Int, _ object: Any) throws -> TypesenseResponse { TypesenseResponse(status: status, data: try JSONSerialization.data(withJSONObject: object)) }
        if path == "/collections" { exists = true; return try response(201, [:]) }
        if path.hasSuffix("/documents/import") {
            let rows = String(decoding: body!, as: UTF8.self).split(separator: "\n")
            for row in rows { let doc = try JSONDecoder().decode(SearchDocument.self, from: Data(row.utf8)); docs[doc.id] = doc }
            return TypesenseResponse(status: 200, data: Data(rows.map { _ in "{\"success\":true}" }.joined(separator: "\n").utf8))
        }
        if path.hasSuffix("/documents/search") {
            // Every document answers, as a stale index would: search must drop the forgotten ones itself.
            return try response(200, ["found": docs.count, "hits": docs.values.map { ["document": ["source_id": $0.source_id, "revision": $0.revision, "summary": "UNTRUSTED_INDEX_SNIPPET"]] }])
        }
        if path.contains("/documents/") { docs.removeValue(forKey: String(path.split(separator: "/").last!)); return try response(200, [:]) }
        return try response(exists ? 200 : 404, [:])
    }
}

@main struct ForgetRangeSearchChecks {
    static var count = 0
    static func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
        guard try value() else { throw MemError.invalid("FAIL: " + name) }
        count += 1; print("PASS: " + name)
    }
    /// Each section is one flow whose steps build on each other: a failed step ends its section, the other still runs.
    @MainActor static func main() {
        setvbuf(stdout, nil, _IOLBF, 0)
        var failed = 0
        do { try indexSide() } catch { failed += 1; print("FAIL index side: \(error)") }
        do { try sheetModel() } catch { failed += 1; print("FAIL sheet model: \(error)") }
        print("forget-range checks: \(count) passed, \(failed) sections failed")
        if failed > 0 { exit(1) }
    }

    static func indexSide() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("macmem-forget-range-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        let review = try store.prepareRetentionChange(.days(30), now: now)
        _ = try store.confirmRetentionChange(review.id, confirmed: true, now: now)
        let config = TypesenseConfiguration(home: home, port: 28108, searchKeyFile: home.appendingPathComponent("search.key").path, syncKeyFile: home.appendingPathComponent("sync.key").path, enabled: true)
        for (path, data) in [(config.searchKeyFile, Data(UUID().uuidString.utf8)), (config.syncKeyFile, Data(UUID().uuidString.utf8)),
                             (home.appendingPathComponent("search-typesense.json").path, try JSONEncoder().encode(config))] {
            try data.write(to: URL(fileURLWithPath: path)); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
        let start = now.addingTimeInterval(-3600), end = now.addingTimeInterval(-1800)
        let rows: [(String, Date, String)] = [("before", start.addingTimeInterval(-60), "Garden sensor"), ("at-start", start, "Garden walrus invoice"),
                                              ("inside", start.addingTimeInterval(600), "Garden marimba lessons"), ("at-end", end, "Garden sensor")]
        for (id, at, title) in rows {
            _ = try store.ingest(Evidence(id: id, at: iso(at), kind: "window.changed", app: "Safari", bundle: "com.apple.Safari", title: title, synthetic: true), now: now)
        }
        let index = FakeIndex()
        _ = try store.syncSearchIndex(config: config, transport: index, now: now)
        try check(index.docs.count == 4 && (try store.rows("SELECT count(*) FROM search_index_state").first?.first) == "4", "fixture: every action is indexed")
        let preview = try store.prepareDeletion(scope: .range(start: start, end: end, timezone: "UTC"), now: now)
        try check(preview.actionIDs == ["at-start", "inside"], "the index fixture's range holds the start and the inside action")
        let receipt = try store.executeDeletion(previewID: preview.id, confirmed: true, now: now)
        try check(receipt.searchCleanup == "pending_source_reads_already_blocked", "until the index syncs, the receipt says its entries are pending and reads are already blocked")
        // Every title says "Garden", so the forgotten rows match the query too and only the forget can drop them (search
        // also re-checks each hit's words against the store, which would drop a row that doesn't match at all).
        let stale = try store.indexedSearch(MemorySearchQuery("Garden"), config: config, transport: index, now: now).items.map(\.id)
        try check(Set(stale) == ["before", "at-end"], "before the sync, search already drops the forgotten hits a stale index returns")
        var guardCount = 0
        while guardCount < 10, try store.syncSearchIndex(config: config, transport: index, now: now).cycleComplete == false { guardCount += 1 }
        try check(index.docs[fingerprint("at-start")] == nil && index.docs[fingerprint("inside")] == nil, "the next sync deletes the forgotten documents from the index")
        try check(index.docs[fingerprint("before")] != nil && index.docs[fingerprint("at-end")] != nil, "the kept documents stay indexed")
        try check(try store.rows("SELECT id FROM search_index_state ORDER BY id").map { $0[0] } == ["at-end", "before"], "the index ledger keeps no forgotten id")
        try check(try store.deletionReceipt(previewID: preview.id)?.searchCleanup == "no_tracked_index_entries", "the receipt then says the index holds nothing of them")
        let indexed = try index.docs.values.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try check(indexed.allSatisfy { !$0.contains("Walrus") && !$0.contains("Marimba") }, "no indexed document carries a forgotten word")
    }
    @MainActor static func settle(_ seconds: Double = 0.3) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// The sheet's question and ranges, then ForgetRangeModel driven against a synthetic store: preview, a commit refused
    /// because the range changed, the commit, Cancel, a slow commit, repeated refusals and Try Again.
    @MainActor static func sheetModel() throws {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        // Sunday, September 27 2026, 3:05 PM in Los Angeles.
        let now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 27, hour: 15, minute: 5))!

        // MARK: strings
        func fake(_ moments: Int?, _ actions: Int, _ s: Date, _ e: Date) -> DeletionPreview {
            DeletionPreview(id: UUID().uuidString, scope: .range(start: s, end: e, timezone: zone.identifier), actionIDs: [], actionCount: actions,
                            revision: "r", expiresAt: iso(now.addingTimeInterval(300)), warning: DeletionPreview.rangeEdges + " " + DeletionPreview.notRecalled,
                            momentCount: moments, rangeStart: MemoryActionScope.range(start: s, end: e, timezone: zone.identifier).start, rangeEnd: MemoryActionScope.range(start: s, end: e, timezone: zone.identifier).end)
        }
        let hourStart = now.addingTimeInterval(-3600)
        try check(ForgetRangeText.question(fake(12, 80, hourStart, now), start: hourStart, end: now, timeZone: zone, now: now) == "Forget 12 moments from 2:05 PM to 3:05 PM?", "question: moments and today's times")
        try check(ForgetRangeText.question(fake(1, 1, hourStart, now), start: hourStart, end: now, timeZone: zone, now: now) == "Forget 1 moment from 2:05 PM to 3:05 PM?", "question: one moment")
        try check(ForgetRangeText.question(fake(0, 3, hourStart, now), start: hourStart, end: now, timeZone: zone, now: now) == "Forget 3 actions from 2:05 PM to 3:05 PM?", "question: actions when no moment shows them")
        let lateStart = calendar.date(from: DateComponents(year: 2026, month: 9, day: 25, hour: 23, minute: 30))!, lateEnd = calendar.date(from: DateComponents(year: 2026, month: 9, day: 26, hour: 0, minute: 30))!
        try check(ForgetRangeText.span(lateStart, lateEnd, timeZone: zone, now: now) == "Sep 25, 11:30 PM to Sep 26, 12:30 AM", "another day's range carries its dates")
        try check(ForgetRangeChoice.today.range(now: now, calendar: calendar, customStart: now, customEnd: now)?.start == calendar.startOfDay(for: now), "Today starts at local midnight and ends now")
        try check(ForgetRangeChoice.last15.range(now: now, calendar: calendar, customStart: now, customEnd: now)?.duration == 900, "Last 15 minutes is 15 minutes to now")
        try check(ForgetRangeChoice.custom.range(now: now, calendar: calendar, customStart: now, customEnd: hourStart) == nil, "a custom range ending before it starts is refused")

        // MARK: the model against a synthetic store
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("forget-range-render-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        for (i, minutes) in [70, 50, 20, 10].enumerated() {
            _ = try store.ingest(Evidence(id: "e\(i)", at: iso(now.addingTimeInterval(Double(-minutes * 60))), kind: "window.changed", app: "Safari", bundle: "com.apple.Safari",
                                          title: "Page \(i)", synthetic: true), now: now)
        }
        var commits = 0, lateAdded = false
        let model = ForgetRangeModel(calendar: calendar, now: { now }, choice: .lastHour,
                                     prepare: { scope in try store.prepareDeletion(scope: scope, now: now) },
                                     commit: { id in
                                         commits += 1
                                         // The first commit meets an action saved into the range after its preview.
                                         if !lateAdded { lateAdded = true; _ = try store.ingest(Evidence(id: "late", at: iso(now.addingTimeInterval(-60)), kind: "window.changed", app: "Safari", bundle: "com.apple.Safari", title: "Late", synthetic: true), now: now) }
                                         _ = try store.executeDeletion(previewID: id, confirmed: true, now: now)
                                     },
                                     release: { try? store.cancelDeletion($0) })
        model.refresh(); settle()
        try check(model.preview?.actionIDs == ["e1", "e2", "e3"], "Last hour previews the hour's actions (the one 70 minutes ago stays out)")
        var finished = false
        model.forget { finished = true }; settle()
        try check(!finished && model.notice == ForgetRangeText.changed && model.preview?.actionIDs == ["e1", "e2", "e3", "late"] && (try store.action("e1", now: now)) != nil,
                  "a commit refused because the range changed deletes nothing and asks again with the new count")
        model.forget { finished = true }; settle()
        try check(finished && commits == 2 && model.phase == .done, "the second Forget commits")
        try check((try store.action("e1", now: now)) == nil && (try store.action("late", now: now)) == nil && (try store.action("e0", now: now)) != nil, "the hour is forgotten; the action before it stays")
        let cancelled = ForgetRangeModel(calendar: calendar, now: { now }, choice: .today, prepare: { scope in try store.prepareDeletion(scope: scope, now: now) }, commit: { _ in }, release: { try? store.cancelDeletion($0) })
        cancelled.refresh(); settle()
        try check(cancelled.preview?.actionIDs == ["e0"], "Today holds what is left of today")
        cancelled.dismiss()
        try check((try store.action("e0", now: now)) != nil, "Cancel deletes nothing")
        // r1 forget-range: Cancel is off while a Forget commits (it can't stop it), and a refused Forget never leaves
        // the sheet stuck with Forget disabled.
        var release: CheckedContinuation<Void, Never>?
        let slow = ForgetRangeModel(calendar: calendar, now: { now }, choice: .today, prepare: { scope in try store.prepareDeletion(scope: scope, now: now) },
                                    commit: { _ in await withCheckedContinuation { release = $0 } }, release: { try? store.cancelDeletion($0) })
        slow.refresh(); settle()
        slow.forget {}; settle()
        try check(slow.phase == .forgetting && !slow.canCancel, "Cancel is off while a Forget commits")
        slow.dismiss()
        try check(slow.phase == .forgetting, "Cancel does nothing while a Forget commits (the delete can't be stopped)")
        release?.resume(); settle()
        try check(slow.phase == .done, "the Forget finishes")
        var refusals = 0
        let refusing = ForgetRangeModel(calendar: calendar, now: { now }, choice: .today, prepare: { scope in try store.prepareDeletion(scope: scope, now: now) },
                                        commit: { _ in refusals += 1; throw MemError.invalid("Deletion scope changed, expired or cancelled; review a new preview") },
                                        release: { try? store.cancelDeletion($0) })
        _ = try store.ingest(Evidence(id: "again", at: iso(now.addingTimeInterval(-30)), kind: "window.changed", app: "Safari", bundle: "com.apple.Safari", title: "Again", synthetic: true), now: now)
        refusing.refresh(); settle()
        for _ in 0..<3 { refusing.forget {}; settle() }
        try check(refusals == 3 && refusing.preview != nil && refusing.canCancel, "every refused Forget asks again with a fresh question; Forget is never left disabled")
        refusing.show(.failed(ForgetRangeText.unavailable), range: nil)
        try check(refusing.canRetry, "a failed question offers Try Again")
        refusing.refresh(); settle()
        try check(refusing.preview != nil, "Try Again prepares the question again")
    }
}
