import Foundation
import MemoryCore

/// "DayDream Preview" (`--preview-sample`): the sample week seeds a scratch store under the temporary folder only,
/// writes every level with the level code's own extractive writer, and its notes are searchable at every level.
/// Nothing here records: the seed only ingests the made-up rows.
func runPreviewChecks(home: URL) throws {
    let zone = "America/Los_Angeles"
    let temp = home.appendingPathComponent("tmp", isDirectory: true)
    try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
    // An evening (8 PM local) so today has a full day of sample rows before the cutoff.
    let now = try DayScope.interval(day: "2026-09-29", timezone: zone).start.addingTimeInterval(20 * 3600)
    let root = PreviewSample.root(temporaryDirectory: temp)

    // Where the preview may write: only under the temporary folder, never a real history's place.
    try check(PreviewSample.allowed(root, temporaryDirectory: temp), "preview root is allowed under the temporary folder")
    let fm = FileManager.default
    let appSupport = fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/DayDream")
    try check(!PreviewSample.allowed(appSupport, temporaryDirectory: temp), "preview refuses Application Support")
    try check(!PreviewSample.allowed(appSupport, temporaryDirectory: fm.homeDirectoryForCurrentUser), "preview refuses Application Support even under the given folder")
    try check(!PreviewSample.allowed(URL(fileURLWithPath: "/private/tmp/daydream-preview"), temporaryDirectory: URL(fileURLWithPath: "/private/tmp")), "preview refuses /private/tmp/daydream-*")
    try check(!PreviewSample.allowed(URL(fileURLWithPath: "/Users/Shared/Preview"), temporaryDirectory: temp), "preview refuses a folder outside the temporary folder")
    try check(!PreviewSample.allowed(temp, temporaryDirectory: temp), "preview refuses the temporary folder itself")
    try check(PreviewSample.root().path.hasPrefix(fm.temporaryDirectory.path), "default preview root is in the temporary folder")
    try check(!PreviewSample.root().path.contains("Application Support"), "default preview root is not Application Support")

    // A folder the preview didn't make is never replaced.
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("keep".utf8).write(to: root.appendingPathComponent("someone-else.txt"))
    var refused = false
    do { try PreviewSample.prepare(root: root, now: now, timezone: zone, temporaryDirectory: temp) } catch { refused = true }
    try check(refused && fm.fileExists(atPath: root.appendingPathComponent("someone-else.txt").path), "preview refuses to replace a folder without its marker")
    try fm.removeItem(at: root)

    let started = Date()
    let (memory, report) = try PreviewSample.prepare(root: root, now: now, timezone: zone, temporaryDirectory: temp)
    print("preview seed: \(report.ingested) rows, \(report.refused) refused, \(report.moments) moments (\(report.modelNotes) model notes, \(report.codeNotes) code notes), levels \(report.levels.sorted { $0.key < $1.key }), \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
    try check(memory.path.hasPrefix(root.path) && fm.fileExists(atPath: root.appendingPathComponent(PreviewSample.marker).path), "preview history sits in its marked folder")
    try check(fm.fileExists(atPath: root.appendingPathComponent("seed-report.json").path), "preview writes its seed report")
    try check(report.days.count == 8, "preview seeds eight days (the week and the multitasking day)")
    try check(report.ingested > 400, "preview ingests the sample week")
    try check(report.moments > 60 && report.modelNotes > 40, "preview moments carry the recorded model notes")
    try check((report.levels["block"] ?? 0) >= 15, "preview writes blocks")
    try check((report.levels["day"] ?? 0) == 8, "preview writes a day note for every day, today included")
    try check((report.levels["week"] ?? 0) >= 1, "preview writes a week note")
    let last = try DayScope.key(now.addingTimeInterval(-45 * 60), timezone: zone)
    try check(report.days.last == last, "preview's last sample day is today")

    // The page's read: today and a past day both have their day note and blocks; a past day has its week.
    let store = try MemoryStore(home: memory)
    let today = try store.dayLevels(day: last, timezone: zone)
    try check(today.day != nil && today.blocks.count >= 3, "today has its day note and blocks")
    try check(today.day?.lines.isEmpty == false, "today's day note has lines")
    let past = try store.dayLevels(day: report.days[report.days.count - 3], timezone: zone)
    try check(past.day != nil && !past.blocks.isEmpty, "a past day has its day note and blocks")
    let weeks = try report.days.compactMap { try store.dayLevels(day: $0, timezone: zone).week }
    try check(!weeks.isEmpty, "a sample day shows its week note")
    try check(weeks.allSatisfy { !$0.title.hasPrefix("Mostly Mostly") }, "week headline reads once")
    let blockMoments = Set(today.blocks.flatMap { $0.children.map(\.id) })
    let todayMoments = try store.dayLayers(day: last, timezone: zone, limit: 1, now: now).activities
    try check(todayMoments.contains { blockMoments.contains($0.id) }, "today's blocks hold today's moments")

    // Search finds lines at every level, with word-start matching.
    var levels = Set<String>()
    for q in ["export", "crash", "email", "tallybird", "asked", "investor", "pricing", "bug"] {
        for hit in try store.noteSearch(q, timezone: zone, now: now) { levels.insert(hit.level) }
    }
    print("preview search levels: \(levels.sorted())")
    try check(levels.isSuperset(of: ["line", "block", "day", "week"]), "preview search finds lines, blocks, days and weeks")
    let hits = try store.noteSearch("export", timezone: zone, now: now)
    try check(!hits.isEmpty && hits.allSatisfy { h in h.text.lowercased().contains("export") || h.noteTitle.lowercased().contains("export") || h.lines.joined(separator: " ").lowercased().contains("export") }, "note hits match the words they were found by")
    try check(hits.filter { ["block", "day", "week"].contains($0.level) }.allSatisfy { !$0.lines.isEmpty }, "level hits carry their note's lines")
    try check(hits.filter { $0.level == "line" }.allSatisfy { $0.momentID != nil && $0.actionID != nil }, "line hits name their moment and action")
    try check(try store.noteSearch("xport", timezone: zone, now: now).isEmpty, "search matches word starts only")
    // A broad query keeps every level hit on every day (notes aren't paged); only moment and line hits are capped.
    let broad = try store.noteSearch("tallybird", timezone: zone, now: now, limit: 5)
    let unbounded = try store.noteSearch("tallybird", timezone: zone, now: now, limit: 100_000)
    let levelKinds: Set<String> = ["month", "week", "day", "block"]
    try check(broad.filter { levelKinds.contains($0.level) }.count == unbounded.filter { levelKinds.contains($0.level) }.count,
              "a broad search keeps every month, week, day and block hit")
    try check(broad.filter { !levelKinds.contains($0.level) }.count == min(5, unbounded.filter { !levelKinds.contains($0.level) }.count),
              "moment and line hits are capped at the limit")
    let oldestDayHit = unbounded.filter { $0.level == "day" }.map(\.day).min()
    try check(oldestDayHit != nil && broad.contains { $0.level == "day" && $0.day == oldestDayHit }, "the oldest day's day note is still found")
    print("preview broad search: \(broad.count) of \(unbounded.count) hits kept for 'tallybird'")

    // The MCP entry reads the preview history only, with a read grant made for it.
    let entryURL = try PreviewSample.writeMCPEntry(root: root, memory: memory, command: URL(fileURLWithPath: "/Applications/Example.app/Contents/MacOS/mac-mem"))
    let perms = (try fm.attributesOfItem(atPath: entryURL.path)[.posixPermissions] as? NSNumber)?.intValue
    try check(perms == 0o600, "preview MCP entry is private")
    let entry = try JSONSerialization.jsonObject(with: Data(contentsOf: entryURL)) as? [String: Any]
    let server = (entry?["mcpServers"] as? [String: Any])?["daydream-preview"] as? [String: Any]
    let args = server?["args"] as? [String] ?? []
    try check(args.contains(memory.path) && args.last == "mcp", "preview MCP entry serves the preview history")

    // Seeding again replaces its own folder.
    let again = try PreviewSample.prepare(root: root, now: now, timezone: zone, temporaryDirectory: temp)
    try check(again.report.ingested == report.ingested && again.report.levels == report.levels, "preview seeds the same week again")
    // A relaunch the same day reuses the sample (no seed); another day, or another seed version, makes it again.
    let t0 = Date()
    let reused = try PreviewSample.prepare(root: root, now: now.addingTimeInterval(60), timezone: zone, temporaryDirectory: temp, reuse: true)
    try check(reused.report == again.report && Date().timeIntervalSince(t0) < 1, "preview reuses today's sample on a relaunch")
    let nextDay = try PreviewSample.prepare(root: root, now: now.addingTimeInterval(86400), timezone: zone, temporaryDirectory: temp, reuse: true)
    try check(nextDay.report.today != again.report.today && nextDay.report.days.last == nextDay.report.today, "preview seeds again on another day")

    // Early in the day: today's rows move earlier as a whole, never squeezed (the day note is still written); before the
    // whole day fits (6 AM here) the week moves back a day.
    let morning = try DayScope.interval(day: "2026-09-30", timezone: zone).start.addingTimeInterval(9 * 3600)
    let early = try PreviewSample.prepare(root: root, now: morning, timezone: zone, temporaryDirectory: temp)
    let earlyStore = try MemoryStore(home: early.memory)
    let earlyToday = try earlyStore.dayLevels(day: "2026-09-30", timezone: zone)
    print("preview seed at 9 AM: \(early.report.moments) moments, \(early.report.modelNotes) model notes, levels \(early.report.levels.sorted { $0.key < $1.key })")
    try check(early.report.fittedToday && early.report.days.last == "2026-09-30" && earlyToday.day != nil && !earlyToday.blocks.isEmpty,
              "at 9 AM today's rows fit before now and today has its day note and blocks")
    let midnight = try DayScope.interval(day: "2026-10-01", timezone: zone).start.addingTimeInterval(20 * 60)
    let late = try PreviewSample.prepare(root: root, now: midnight, timezone: zone, temporaryDirectory: temp)
    try check(late.report.movedBackADay && late.report.days.last == "2026-09-30" && late.report.days.count == 8,
              "just after midnight the busiest day is yesterday")
    let dawn = try PreviewSample.prepare(root: root, now: DayScope.interval(day: "2026-10-01", timezone: zone).start.addingTimeInterval(6 * 3600),
                                         timezone: zone, temporaryDirectory: temp)
    try check(dawn.report.movedBackADay && !dawn.report.fittedToday, "at 6 AM the busiest day is never squeezed to fit: it is yesterday")
}
