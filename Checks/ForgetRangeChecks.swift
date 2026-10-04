import Foundation
import CSQLite
import MemoryCore

/// Forget a time range (Preview 4): a "range" scope deletes every action with start <= t < end through the same
/// preview -> confirm -> commit path as a moment or a day; a moment crossing an edge keeps only its outside actions;
/// nothing written from a forgotten action is left in any table; day, week and month notes are dropped and written
/// again from what is left. Synthetic stores only.
func runForgetRangeChecks(home: URL) throws {
    try runForgetRangeCore(home: home.appendingPathComponent("core"))
    try runForgetRangeDST(home: home.appendingPathComponent("dst"))
    try runForgetRangeFrozen(home: home.appendingPathComponent("frozen"))
}

/// r1 forget-range: a range over a day whose actions history retention already took still has its frozen day, week and
/// month summaries on screen; the range Forget offers them ("written summaries") and deletes them.
private func runForgetRangeFrozen(home: URL) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000), zone = "UTC", day = "2027-01-14"
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    let review = try store.prepareRetentionChange(.days(30), now: now)
    _ = try store.confirmRetentionChange(review.id, confirmed: true, now: now)
    let start = try DayScope.interval(day: day, timezone: zone).start
    for (id, m) in [("f1", 0), ("f2", 4)] {
        _ = try store.ingest(Evidence(id: id, at: iso(start.addingTimeInterval(Double(9 * 3600 + m * 60))), kind: "window.changed", app: "Mail", bundle: "com.apple.mail", title: "Walrus invoice", synthetic: true), now: now)
    }
    for m in try store.dayLayers(day: day, timezone: zone, now: now).activities {
        let request = try store.prepareNote(kind: "activity", day: day, timezone: zone, activityID: m.id, now: now)
        _ = try store.commitNote(NoteWriterOutput(requestID: request.id, title: "Walrus invoice", bullets: [NoteBullet(text: "Read the Walrus invoice in Mail.", actionIDs: request.actions.map(\.id), assertion: "observed")],
                                                  generator: "local/synthetic", generatorVersion: "1"), now: now)
    }
    while let next = try store.levelWork(timezone: zone, now: now).first {
        let x = LevelGrounding.extractive(next)
        try store.commitLevel(next, title: x.title, lines: x.lines, generator: LevelWriterVersion.extractive, now: now)
    }
    let later = now.addingTimeInterval(40 * 86400)
    _ = try store.writePending(now: later)
    let frozen = try store.allLevelNotes().filter(\.frozen)
    try check((try store.action("f1", now: later)) == nil && frozen.contains { $0.level == .day }, "frozen fixture: retention took the actions and froze the day above them")
    let scope = MemoryActionScope.range(start: start, end: start.addingTimeInterval(86400), timezone: zone)
    let preview = try store.prepareDeletion(scope: scope, now: later)
    try check(preview.actionCount == 0 && (preview.summaryCount ?? 0) == frozen.count, "a range with only frozen summaries left has a preview that counts them (\(preview.summaryCount ?? 0))")
    _ = try store.executeDeletion(previewID: preview.id, confirmed: true, now: later)
    try check(try store.allLevelNotes().isEmpty, "the range Forget deletes the frozen day, week and month summaries of expired history")
    var empty = false
    do { _ = try store.prepareDeletion(scope: scope, now: later) } catch MemError.invalid(let why) { empty = why == DeletionPreview.nothingInRange }
    try check(empty, "then the range has nothing saved")
}

/// Every table's rows as text (raw SQLite, read only): what "nothing left behind" is checked against.
private func forgetRangeTables(_ store: MemoryStore) throws -> [String: [String]] {
    var db: OpaquePointer?
    guard sqlite3_open_v2(store.home.appendingPathComponent("memory.sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw MemError.database("check open") }
    defer { sqlite3_close(db) }
    func query(_ sql: String) throws -> [[String]] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { throw MemError.database("check prepare " + sql) }
        defer { sqlite3_finalize(stmt) }
        var out = [[String]]()
        while sqlite3_step(stmt) == SQLITE_ROW {
            out.append((0..<sqlite3_column_count(stmt)).map { i in sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? "" })
        }
        return out
    }
    var result = [String: [String]]()
    for table in try query("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'").map({ $0[0] }) {
        result[table] = try query("SELECT * FROM \"\(table)\"").map { $0.joined(separator: "\u{1f}") }
    }
    return result
}

private func runForgetRangeCore(home: URL) throws {
    let zone = "America/Los_Angeles"
    let d1 = "2027-01-14", d2 = "2027-01-15"
    let now = Date(timeIntervalSince1970: 1_800_100_000 + 86400)   // 2027-01-17 11:46 UTC: both days are closed
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    let review = try store.prepareRetentionChange(.days(30), now: now)
    _ = try store.confirmRetentionChange(review.id, confirmed: true, now: now)
    var consent = try store.policy(); consent.captureText = true; consent.typedConsentVersion = 1; try store.updatePolicy(consent, now: now)
    try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore()), now: now); try store.setUpTypedVault(now: now)
    try store.acceptSafeTyping(now: now)
    func local(_ day: String, _ h: Int, _ m: Int, _ s: Int = 0) -> Date { try! DayScope.interval(day: day, timezone: zone).start.addingTimeInterval(Double(h * 3600 + m * 60 + s)) }
    func window(_ id: String, _ at: Date, _ app: String, _ bundle: String, _ title: String) -> Evidence {
        Evidence(id: id, at: iso(at), kind: "window.changed", app: app, bundle: bundle, title: title, synthetic: true)
    }
    let rangeStart = local(d1, 23, 30), rangeEnd = local(d2, 0, 30)   // crosses local midnight in Los Angeles
    let events = [
        window("keep-early-1", local(d1, 10, 0), "Xcode", "com.apple.dt.Xcode", "ExportView.swift — tallybird"),
        window("keep-early-2", local(d1, 10, 4), "Xcode", "com.apple.dt.Xcode", "ExportView.swift — tallybird"),
        // The moment that crosses the start: two actions before it, one exactly at it, one typed inside.
        window("trip-1", local(d1, 23, 20), "Notes", "com.apple.Notes", "Trip list"),
        window("trip-2", local(d1, 23, 25), "Notes", "com.apple.Notes", "Trip list"),
        window("trip-start", rangeStart, "Notes", "com.apple.Notes", "Trip list"),
        Evidence(id: "trip-typed", at: iso(local(d1, 23, 35)), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes", title: "Trip list", text: "zanzibarquokka rope", synthetic: true),
        window("gone-mail", local(d1, 23, 50), "Mail", "com.apple.mail", "Walrus invoice"),
        window("gone-music", local(d2, 0, 10), "Music", "com.apple.Music", "Midnight Marimba"),
        window("keeper-end", rangeEnd, "Xcode", "com.apple.dt.Xcode", "Keeper.swift — tallybird"),
        window("keeper-2", local(d2, 0, 34), "Xcode", "com.apple.dt.Xcode", "Keeper.swift — tallybird"),
        window("breakfast", local(d2, 9, 0), "Mail", "com.apple.mail", "Breakfast plans"),
    ]
    for e in events { _ = try store.ingest(e, now: now) }
    // A distinctive line for each action; forgotten ones carry words nothing kept uses.
    let lines: [String: String] = [
        "keep-early-1": "Had ExportView.swift open in Xcode.", "keep-early-2": "Had ExportView.swift open in Xcode.",
        "trip-1": "Opened the trip list in Notes.", "trip-2": "Opened the trip list in Notes.",
        "trip-start": "Listed gear for the Kilimanjaro climb.", "trip-typed": "Wrote Kilimanjaro packing notes.",
        "gone-mail": "Read the Walrus invoice in Mail.", "gone-music": "Played Midnight Marimba in Music.", "gone-late": "Read Narwhal notes in Mail.",
        "keeper-end": "Had Keeper.swift open in Xcode.", "keeper-2": "Had Keeper.swift open in Xcode.", "breakfast": "Read Breakfast plans in Mail.",
    ]
    let forgottenWords = ["Kilimanjaro", "Walrus", "Marimba", "Narwhal", "zanzibarquokka"]
    func writeMomentNotes() throws {
        for day in [d1, d2] {
            for m in try store.dayLayers(day: day, timezone: zone, limit: 1, now: now).activities where m.status != "ready" {
                let request = try store.prepareNote(kind: "activity", day: day, timezone: zone, activityID: m.id, now: now)
                var bullets = [NoteBullet]()
                for id in request.actions.map(\.id) {
                    let text = lines[id] ?? "Had \(m.subject) open."
                    if let i = bullets.firstIndex(where: { $0.text == text }) { bullets[i].actionIDs.append(id) }
                    else { bullets.append(NoteBullet(text: text, actionIDs: [id], assertion: "observed")) }
                }
                _ = try store.commitNote(NoteWriterOutput(requestID: request.id, title: m.subject, bullets: bullets, generator: "local/synthetic", generatorVersion: "1"), now: now)
            }
        }
    }
    func writeLevels() throws -> Int {
        var count = 0
        while count < 100, let request = try store.levelWork(timezone: zone, now: now, backfillDays: 8, limit: 1).first {
            count += 1
            let (title, lines) = LevelGrounding.extractive(request)
            _ = try store.commitLevel(request, title: title, lines: lines, generator: LevelWriterVersion.extractive, now: now)
        }
        return count
    }
    func levelRows() throws -> [(level: String, period: String, body: String)] {
        (try forgetRangeTables(store)["level_notes"] ?? []).map { row in
            let f = row.components(separatedBy: "\u{1f}")   // id, level, period, start, typed, frozen, body
            return (f[1], f[2], f[6])
        }
    }
    try writeMomentNotes()
    _ = try writeLevels()
    let levelsBefore = try levelRows()
    let upperBefore = Set(levelsBefore.filter { $0.level != "block" }.map { $0.level + " " + $0.period })
    try check(upperBefore.contains("day " + d1) && upperBefore.contains("day " + d2) && levelsBefore.contains { $0.level == "week" },
              "range fixture: both local days and their week are written")
    try check(levelsBefore.contains { $0.body.contains("Walrus") } && levelsBefore.contains { $0.body.contains("\"gone-music\"") },
              "range fixture: level notes mention what the range will forget (so the check below means something)")
    try check(try store.typedCounts().sealed == 1, "range fixture: the typed row is sealed")
    try check((try forgetRangeTables(store)["generated_notes"] ?? []).contains { $0.contains("Kilimanjaro") }
              && (try Data(contentsOf: home.appendingPathComponent("memory.sqlite"))).range(of: Data("Walrus".utf8)) != nil,
              "range fixture: moment notes and the database file hold the words the range will forget")

    // MARK: preview
    let scope = MemoryActionScope.range(start: rangeStart, end: rangeEnd, timezone: zone)
    try check(scope.start == "2027-01-15T07:30:00.000Z" && scope.end == "2027-01-15T08:30:00.000Z", "a Los Angeles range across local midnight is exact UTC instants")
    let preview = try store.prepareDeletion(scope: scope, now: now)
    try check(preview.actionIDs == ["gone-mail", "gone-music", "trip-start", "trip-typed"], "start <= t < end: the action exactly at the start is in, the one exactly at the end is out, from both local days")
    try check(preview.actionCount == 4 && preview.momentCount == 3, "preview counts actions and the moments they touch (the crossing moment counts)")
    try check(preview.rangeStart == scope.start && preview.rangeEnd == scope.end && preview.warning.hasPrefix(DeletionPreview.rangeEdges), "preview returns the exact range and the edge rule")
    // The same instants written with an offset, shown in another zone: the same actions.
    let tokyo = MemoryActionScope(kind: "range", timezone: "Asia/Tokyo", start: "2027-01-14T23:30:00-08:00", end: "2027-01-15T00:30:00-08:00")
    let tokyoPreview = try store.prepareDeletion(scope: tokyo, now: now)
    try check(tokyoPreview.actionIDs == preview.actionIDs, "a range is instants: the display zone and offset spelling never move it")
    try store.cancelDeletion(tokyoPreview.id)
    var emptyRefused = false
    do { _ = try store.prepareDeletion(scope: .range(start: local(d1, 3, 0), end: local(d1, 4, 0), timezone: zone), now: now) }
    catch MemError.invalid(let why) { emptyRefused = why == DeletionPreview.nothingInRange }
    try check(emptyRefused, "an empty range has no preview: nothing saved in that range")
    var backwardsRefused = false
    do { _ = try store.prepareDeletion(scope: .range(start: rangeEnd, end: rangeStart, timezone: zone), now: now) } catch { backwardsRefused = true }
    try check(backwardsRefused, "a range whose end is not after its start is refused")

    // MARK: changed between preview and confirm
    _ = try store.ingest(window("gone-late", local(d1, 23, 55), "Mail", "com.apple.mail", "Narwhal notes"), now: now)
    var changedRefused = false
    do { _ = try store.executeDeletion(previewID: preview.id, confirmed: true, now: now) } catch { changedRefused = true }
    try check(changedRefused && (try store.action("gone-mail", now: now)) != nil, "an action saved into the range after the preview: the commit is refused and nothing is deleted")
    var fresh = try store.prepareDeletion(scope: scope, now: now)
    var expiredRefused = false
    do { _ = try store.executeDeletion(previewID: fresh.id, confirmed: true, now: now.addingTimeInterval(301)) } catch { expiredRefused = true }
    try check(expiredRefused && (try store.action("gone-mail", now: now)) != nil, "an expired range preview is refused")
    fresh = try store.prepareDeletion(scope: scope, now: now)
    try store.cancelDeletion(fresh.id)
    var cancelledRefused = false
    do { _ = try store.executeDeletion(previewID: fresh.id, confirmed: true, now: now) } catch { cancelledRefused = true }
    try check(cancelledRefused, "a cancelled range preview is refused")

    // MARK: commit
    let final = try store.prepareDeletion(scope: scope, now: now)
    try check(final.actionIDs == ["gone-late", "gone-mail", "gone-music", "trip-start", "trip-typed"] && final.momentCount == 4, "the new preview has the late action")
    // r1 forget-range: something saved outside the range meanwhile (a typing burst, a Chrome page) doesn't refuse it.
    _ = try store.ingest(window("outside-save", local(d2, 10, 0), "Safari", "com.apple.Safari", "Weather"), now: now)
    let receipt = try store.executeDeletion(previewID: final.id, confirmed: true, now: now)
    try check(receipt.actionIDs == final.actionIDs, "range forget commits exactly the previewed actions, although something was saved outside the range meanwhile")
    for id in final.actionIDs { try check(try store.action(id, now: now) == nil && store.read(id, now: now) == nil, "forgotten: " + id) }
    for id in ["keep-early-1", "trip-1", "trip-2", "keeper-end", "keeper-2", "breakfast"] { try check(try store.action(id, now: now) != nil, "kept: " + id) }
    let straddle = try store.dayLayers(day: d1, timezone: zone, limit: 1, now: now).activities.first { $0.actionIDs.contains("trip-1") }
    try check(straddle?.actionIDs == ["trip-1", "trip-2"] && straddle?.status != "ready", "the crossing moment keeps only its outside actions, and its note waits to be written again (not left ready)")
    try check(try store.typedCounts().sealed == 0 && store.typedCounts().after == 0, "the typed row's sealed words and stub are gone")

    // Nothing left behind: every table, every row. Ids may stay only as tombstones (they keep a deleted action from
    // coming back) and in the deletion's own preview and receipt.
    func leftovers() throws -> [String] {
        var found = [String]()
        for (table, rows) in try forgetRangeTables(store) {
            for row in rows {
                for word in forgottenWords where row.localizedCaseInsensitiveContains(word) { found.append(table + ": " + word) }
                if !["tombstones", "deletion_previews"].contains(table) {
                    for id in final.actionIDs where row.contains("\"" + id + "\"") || row.hasPrefix(id + "\u{1f}") || row == id { found.append(table + ": " + id) }
                }
            }
        }
        return found
    }
    let after = try leftovers()
    try check(after.isEmpty, "nothing left behind in any table (records, summaries, generated_notes, level_notes, level_edges, typed_text, note_requests, search_index_state, ...)" + (after.isEmpty ? "" : ": " + after.joined(separator: ", ")))
    let bytes = try Data(contentsOf: home.appendingPathComponent("memory.sqlite"))
    try check(forgottenWords.allSatisfy { bytes.range(of: Data($0.utf8)) == nil }, "the database file keeps no forgotten words (secure delete)")
    let tables = try forgetRangeTables(store)
    try check(Set(final.actionIDs).isSubset(of: Set(tables["tombstones"] ?? [])), "forgotten actions are tombstoned")

    // MARK: levels rebuild from what is left
    let levelsAfter = try levelRows()
    try check(!levelsAfter.contains { $0.level == "day" && ($0.period == d1 || $0.period == d2) } && !levelsAfter.contains { $0.level == "week" || $0.level == "month" },
              "the day, week and month notes above forgotten blocks are dropped, not frozen")
    try check(levelsAfter.contains { $0.level == "block" && $0.body.contains("ExportView") } && levelsAfter.contains { $0.level == "block" && $0.body.contains("Breakfast") },
              "blocks with nothing forgotten stay")
    try writeMomentNotes()
    try check(try store.dayLayers(day: d1, timezone: zone, limit: 1, now: now).activities.first { $0.actionIDs.contains("trip-1") }?.status == "ready", "the crossing moment's note is written again from what is left")
    _ = try writeLevels()
    let rebuilt = try levelRows()
    let upperAfter = Set(rebuilt.filter { $0.level != "block" }.map { $0.level + " " + $0.period })
    try check(upperBefore.isSubset(of: upperAfter), "every dropped day, week and month note is written again (" + upperBefore.sorted().joined(separator: ", ") + ")")
    try check(rebuilt.contains { $0.level == "block" && $0.body.contains("\"actionIDs\":[\"keeper-end\",\"keeper-2\"]") }, "the block the range cut into is written again from what is left")
    try check(rebuilt.allSatisfy { r in !forgottenWords.contains { r.body.localizedCaseInsensitiveContains($0) } } && (try leftovers()).isEmpty,
              "no summary at any level mentions forgotten content after the rebuild")
}

/// A local day across the spring-forward change (23 hours in Los Angeles) as a range: exactly that day's actions.
private func runForgetRangeDST(home: URL) throws {
    let zone = "America/Los_Angeles"
    let now = try DayScope.interval(day: "2027-03-16", timezone: zone).start
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    let review = try store.prepareRetentionChange(.days(30), now: now)
    _ = try store.confirmRetentionChange(review.id, confirmed: true, now: now)
    let day = try DayScope.interval(day: "2027-03-14", timezone: zone)
    try check(day.duration == 23 * 3600, "DST fixture: the spring-forward day is 23 hours")
    let times: [(String, Date)] = [("before", day.start.addingTimeInterval(-1)), ("first", day.start), ("pre-jump", day.start.addingTimeInterval(1 * 3600 + 59 * 60)),
                                   ("post-jump", day.start.addingTimeInterval(2 * 3600 + 1 * 60)), ("last", day.end.addingTimeInterval(-1)), ("next", day.end)]
    for (id, at) in times { _ = try store.ingest(Evidence(id: id, at: iso(at), kind: "window.changed", app: "Safari", bundle: "com.apple.Safari", title: "Page " + id, synthetic: true), now: now) }
    let preview = try store.prepareDeletion(scope: .range(start: day.start, end: day.end, timezone: zone), now: now)
    try check(preview.actionIDs == ["first", "last", "post-jump", "pre-jump"], "a range over a DST day holds that local day's actions only")
    _ = try store.executeDeletion(previewID: preview.id, confirmed: true, now: now)
    try check(try store.action("before", now: now) != nil && store.action("next", now: now) != nil && store.action("first", now: now) == nil, "DST range: its neighbours stay")
}
