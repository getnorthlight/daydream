import Foundation
import MemoryCore

/// claude/catchup-1003: `status`/`doctor` report the moments waiting for a note (`MemoryStore.noteBacklog`), not the
/// record-summary count that read 0 while past days waited. Synthetic actions only.
func runNoteBacklogChecks(home: URL) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000), zone = "UTC"   // 2027-01-15 08:00 UTC
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    let review = try store.prepareRetentionChange(.days(30), now: now)
    _ = try store.confirmRetentionChange(review.id, confirmed: true, now: now)
    let day = "2027-01-14"
    func at(_ h: Int, _ m: Int) -> String { iso(try! DayScope.interval(day: day, timezone: zone).start.addingTimeInterval(Double(h * 3600 + m * 60))) }
    let events = [
        Evidence(id: "nb-x1", at: at(9, 0), kind: "window.changed", app: "Xcode", bundle: "com.apple.dt.Xcode", title: "ExportView.swift — tallybird", synthetic: true),
        Evidence(id: "nb-x2", at: at(9, 4), kind: "window.changed", app: "Xcode", bundle: "com.apple.dt.Xcode", title: "ExportView.swift — tallybird", synthetic: true),
        Evidence(id: "nb-s1", at: at(10, 10), kind: "window.changed", app: "Safari", bundle: "com.apple.Safari", title: "Flights to Tokyo", synthetic: true),
        Evidence(id: "nb-s2", at: at(10, 14), kind: "window.changed", app: "Safari", bundle: "com.apple.Safari", title: "Flights to Tokyo", synthetic: true),
        Evidence(id: "nb-n1", at: at(11, 20), kind: "window.changed", app: "Music", bundle: "com.apple.Music", title: "Evening playlist", synthetic: true),
        Evidence(id: "nb-n2", at: at(11, 24), kind: "window.changed", app: "Music", bundle: "com.apple.Music", title: "Evening playlist", synthetic: true),
    ]
    for e in events { _ = try store.ingest(e, now: now) }
    let empty = try store.noteBacklog(now: now, timezone: zone)
    let moments = try store.dayLayers(day: day, timezone: zone, now: now).activities.sorted { $0.start < $1.start }
    try check(moments.count == 3, "note backlog fixture: three moments yesterday (\(moments.count))")
    try check(empty.waiting == 3 && empty.updating == 0 && empty.pending == 3 && empty.byDay == [day: 3],
              "status pending: three moments with no note are 3 pending (\(empty))")
    // One written by this writer (ready), one by an earlier writer version (still shown, waiting for its rewrite).
    func write(_ m: ActivityNote, version: String) throws {
        let request = try store.prepareNote(kind: "activity", day: day, timezone: zone, activityID: m.id, now: now)
        _ = try store.commitNote(NoteWriterOutput(requestID: request.id, title: m.subject, bullets: [NoteBullet(text: "Had \(m.subject) open.", actionIDs: request.actions.map(\.id), assertion: "observed")],
                                                  generator: "local/synthetic", generatorVersion: version), now: now)
    }
    try write(moments[0], version: NoteWriterVersions.current[0])
    try write(moments[1], version: "qwen35-4b-q4-b9723-prompt1-validator1")
    let after = try store.noteBacklog(now: now, timezone: zone)
    try check(after.ready == 1 && after.updating == 1 && after.waiting == 1 && after.pending == 2 && after.byDay == [day: 2],
              "status pending: a current note is ready, an earlier writer's note is updating (still shown), the third still waits (\(after))")
    let layers = try store.dayLayers(day: day, timezone: zone, now: now)
    let older = layers.activities.first { $0.id == moments[1].id }
    try check(older?.status == "pending" && older?.previous != nil, "an earlier writer's note stays readable as `previous` until it is rewritten")
    try check(AssistantView.note(older?.generated ?? older?.previous)?.points == ["Had \(moments[1].subject) open."], "AI apps read the earlier writer's note until it is rewritten")
    // A note DayDream's code wrote never says a cloud model wrote it (MCP status).
    try check(AssistantView.noteGenerator("code/moment-notes") == "DayDream on this Mac" && AssistantView.noteGenerator("local/qwen").contains("on this Mac")
              && AssistantView.noteGenerator("openrouter/x").contains("cloud"), "MCP status: code notes are DayDream's on this Mac, not a cloud model's")
    // Days beyond the window are not counted.
    try check(try store.noteBacklog(now: now.addingTimeInterval(9 * 86400), timezone: zone).pending == 0, "status pending: only today and the 7 days before it")
}
