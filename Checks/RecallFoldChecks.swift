import Foundation
import MemoryCore

/// claude/recall-1004: a day-level recall with no notes yet listed every moment on its own line (an AI app read about 90
/// lines, many a bare "Messages (no note yet)" at the same minute). Back-to-back moments with no note from the same app
/// and the same title (for Messages, the same conversation) now fold into one line with a time range, a count and one
/// open handle that lists them; lines are capped and the reply says how many were folded or left out. Synthetic store
/// only: made-up titles and names, no typed words.
func runRecallFoldChecks(home: URL) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC
    let zone = "UTC", day = "2027-01-14", busy = "2027-01-13"
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    let review = try store.prepareRetentionChange(.days(30), now: now)
    _ = try store.confirmRetentionChange(review.id, confirmed: true, now: now)
    func at(_ d: String, _ h: Int, _ m: Int, _ s: Int = 0) -> String {
        iso(try! DayScope.interval(day: d, timezone: zone).start.addingTimeInterval(Double(h * 3600 + m * 60 + s)))
    }
    var n = 0
    func window(_ d: String, _ h: Int, _ m: Int, _ s: Int, _ app: String, _ bundle: String, _ title: String) -> Evidence {
        n += 1
        return Evidence(id: "fold-\(n)", at: at(d, h, m, s), kind: "window.changed", app: app, bundle: bundle, title: title, synthetic: true)
    }
    let xcode = ("Xcode", "com.apple.dt.Xcode", "ExportView.swift — tallybird")
    let sms = ("Messages", "com.apple.MobileSMS")
    var events = [window(day, 9, 50, 0, xcode.0, xcode.1, xcode.2)]
    // Four anonymous Messages visits in the same minute, each between two looks at the same Xcode file: four moments.
    for i in 0..<4 {
        events.append(window(day, 10, 1, i * 20, sms.0, sms.1, "Messages"))
        events.append(window(day, 10, 1, i * 20 + 10, xcode.0, xcode.1, xcode.2))
    }
    // The same note three times, 25 minutes apart (each its own moment), then once more much later.
    for m in [0, 25, 50] { events.append(window(day, 12, m, 0, "Notes", "com.apple.Notes", "Groceries")) }
    events.append(window(day, 13, 10, 0, "Safari", "com.apple.Safari", "Flights to Tokyo"))
    events.append(window(day, 14, 30, 0, "Notes", "com.apple.Notes", "Groceries"))
    // Two visits to one conversation 25 minutes apart, then another conversation: only the first two fold.
    events.append(window(day, 15, 0, 0, sms.0, sms.1, "Maya"))
    events.append(window(day, 15, 25, 0, sms.0, sms.1, "Maya"))
    events.append(window(day, 15, 26, 0, sms.0, sms.1, "Leo"))
    // A busy day: 45 different notes, two minutes apart (nothing folds; the reply is capped).
    for i in 0..<45 { events.append(window(busy, 9, i * 2, 0, "Notes", "com.apple.Notes", "Plan \(["alpha", "bravo", "delta"][i % 3]) \(i + 100)")) }
    for e in events { _ = try store.ingest(e, now: now) }

    // The Safari moment has a note: it always keeps its own line.
    let moments = try store.dayLayers(day: day, timezone: zone, now: now).activities
    try check(moments.count == 13, "fold fixture: 13 moments on the day (\(moments.count): \(moments.map(\.subject)))")
    guard let flights = moments.first(where: { $0.subject == "Flights to Tokyo" }) else { throw MemError.invalid("FAILED: fold fixture has its Safari moment") }
    let request = try store.prepareNote(kind: "activity", day: day, timezone: zone, activityID: flights.id, now: now)
    _ = try store.commitNote(NoteWriterOutput(requestID: request.id, title: "Flights to Tokyo",
                                              bullets: [NoteBullet(text: "Compared flights to Tokyo.", actionIDs: request.actions.map(\.id), assertion: "observed")],
                                              generator: "local/synthetic", generatorVersion: "1"), now: now)

    func object(_ text: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:] }
    let detailed = try store.assistantRecall(level: "day", when: day, open: nil, query: nil, timezone: zone, now: now)
    let node = object(detailed)
    let rows = node["children"] as? [[String: Any]] ?? []
    func titled(_ t: String) -> [[String: Any]] { rows.filter { $0["title"] as? String == t } }
    try check(rows.count == 7, "a day of 13 moments reads as 7 lines (\(rows.count))")
    let messages = titled("Messages")
    try check(messages.count == 1 && messages[0]["count"] as? Int == 4 && messages[0]["level"] as? String == "moments",
              "four back-to-back Messages moments with no note fold into one line with a count")
    try check((messages.first?["when"] as? String)?.contains(" to ") == true, "a folded line has a time range")
    try check(messages.first?["written"] as? String == "no note yet", "a folded line says it has no note yet")
    try check(titled("Groceries").map { $0["count"] as? Int ?? 1 } == [3, 1], "three Groceries moments 25 minutes apart fold; one 100 minutes later doesn't")
    try check(titled("Flights to Tokyo").count == 1 && titled("Flights to Tokyo")[0]["count"] == nil, "a moment with a note keeps its own line")
    try check(titled("Maya").first?["count"] as? Int == 2 && titled("Leo").count == 1 && titled("Leo")[0]["count"] == nil,
              "two visits to one conversation fold; another conversation never folds into it")
    try check((node["folded"] as? String)?.hasPrefix("9 back-to-back moments with no note yet are folded into 3 lines") == true,
              "the reply says how many moments were folded (\(node["folded"] ?? "none"))")
    try check(node["left_out"] == nil, "nothing is left out of a 7-line day")

    // The folded line's handle lists its moments, each with its own handle that still opens.
    guard let handle = messages.first?["open"] as? String, handle.hasPrefix("moments:") else { throw MemError.invalid("FAILED: a folded line has one open handle") }
    let expanded = object(try store.assistantRecall(level: nil, when: nil, open: handle, query: nil, timezone: zone, now: now))
    let parts = expanded["children"] as? [[String: Any]] ?? []
    try check(parts.count == 4 && parts.allSatisfy { ($0["open"] as? String)?.hasPrefix("moment:") == true }, "a folded line's handle lists its 4 moments")
    let one = object(try store.assistantRecall(level: nil, when: nil, open: parts[0]["open"] as? String, query: nil, timezone: zone, now: now))
    try check(one["level"] as? String == "moment", "each listed moment opens on its own")
    do {
        _ = try store.assistantRecall(level: nil, when: nil, open: "moments:activity_gone..activity_gone2@" + day, query: nil, timezone: zone, now: now)
        try check(false, "a folded handle whose moments are gone is refused")
    } catch MemError.invalid(let message) { try check(message.contains("gone"), "a folded handle whose moments are gone says so") }

    // Concise Markdown: one line per fold with its count, the fold count said, and no repeated bare lines.
    let concise = AssistantMarkdown.render(tool: "recall", body: detailed, now: now, zone: TimeZone(identifier: zone)!)
    let bare = concise.components(separatedBy: "\n").filter { $0.contains("Messages (no note yet)") }
    try check(bare.count == 1 && bare[0].contains("4 moments: Messages"), "concise recall shows the Messages visits once, with their count")
    try check(concise.contains("9 back-to-back moments with no note yet are folded into 3 lines"), "concise recall says how many were folded")
    try check(concise.components(separatedBy: "\n").filter { $0.hasPrefix("- ") }.count == 7, "concise recall lists 7 lines for the day")

    // A block-level recall before any block is written lists the folded moments (it listed nothing in concise form).
    let afternoon = try store.assistantRecall(level: "block", when: day + " afternoon", open: nil, query: nil, timezone: zone, now: now)
    let afternoonText = AssistantMarkdown.render(tool: "recall", body: afternoon, now: now, zone: TimeZone(identifier: zone)!)
    try check(afternoonText.contains("Inside:") && afternoonText.contains("2 moments: Maya") && afternoonText.contains("Leo"),
              "a block-level recall shows its moments, folded")

    // A busy day is capped, and says how many lines it left out.
    let busyNode = object(try store.assistantRecall(level: "day", when: busy, open: nil, query: nil, timezone: zone, now: now))
    try check((busyNode["children"] as? [Any])?.count == 40, "a day with 45 different moments lists at most 40 lines")
    try check((busyNode["left_out"] as? String)?.hasPrefix("5 later lines not shown") == true, "a capped day says how many lines it left out")
}
