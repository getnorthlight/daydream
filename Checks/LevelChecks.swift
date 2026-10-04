import Foundation
import MemoryCore
import PrivacyPolicy

/// Levels of memory (summaries/v3): blocks, days, weeks and months are written only from the level below, link down
/// to it, rebuild when it grows, and go (or freeze) when what they were written from goes. Synthetic store only.
func runLevelChecks(home: URL) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00 UTC
    let zone = "UTC"
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    let review = try store.prepareRetentionChange(.days(30), now: now)
    _ = try store.confirmRetentionChange(review.id, confirmed: true, now: now)
    var consent = try store.policy(); consent.captureText = true; consent.typedConsentVersion = 1; try store.updatePolicy(consent, now: now)
    try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore()), now: now); try store.setUpTypedVault(now: now)
    try store.acceptSafeTyping(now: now)
    let day = "2027-01-14"
    func at(_ h: Int, _ m: Int) -> String { iso(try! DayScope.interval(day: day, timezone: zone).start.addingTimeInterval(Double(h * 3600 + m * 60))) }
    func window(_ id: String, _ h: Int, _ m: Int, _ app: String, _ bundle: String, _ title: String) -> Evidence {
        Evidence(id: id, at: at(h, m), kind: "window.changed", app: app, bundle: bundle, title: title, synthetic: true)
    }
    let events = [
        window("a1-1", 9, 0, "Xcode", "com.apple.dt.Xcode", "ExportView.swift — tallybird"), window("a1-2", 9, 4, "Xcode", "com.apple.dt.Xcode", "ExportView.swift — tallybird"),
        window("a2-1", 9, 20, "Claude", "com.anthropic.claudefordesktop", "Export crash"), window("a2-2", 9, 24, "Claude", "com.anthropic.claudefordesktop", "Export crash"),
        window("a3-1", 9, 40, "Mail", "com.apple.mail", "Export bug"), window("a3-2", 9, 44, "Mail", "com.apple.mail", "Export bug"),
        window("b1-1", 14, 0, "Safari", "com.apple.Safari", "Flights to Tokyo"), window("b1-2", 14, 5, "Safari", "com.apple.Safari", "Flights to Tokyo"),
        window("b2-1", 14, 20, "Notes", "com.apple.Notes", "Tokyo trip"),
        Evidence(id: "b2-2", at: at(14, 22), kind: "keyboard.text_input", app: "Notes", bundle: "com.apple.Notes", title: "Tokyo trip", text: "passport, adapter, rail pass", synthetic: true),
        window("c1-1", 20, 0, "Music", "com.apple.Music", "Evening playlist"),
    ]
    for e in events { _ = try store.ingest(e, now: now) }
    let bullets: [String: (String, String)] = [
        "ExportView.swift — tallybird": ("ExportView.swift in Xcode", "Had ExportView.swift open in Xcode."),
        "Export crash": ("Export crash", "Asked Claude to find why export crashes on big files."),
        "Export bug": ("Export bug", "Drafted an email to Priya about the export bug."),
        "Flights to Tokyo": ("Flights to Tokyo", "Had Flights to Tokyo open in Safari."),
        "Tokyo trip": ("Tokyo trip", "Wrote a packing list for the Tokyo trip in Notes."),
        "Evening playlist": ("Evening playlist", "Had Evening playlist open in Music."),
        "Hotels in Tokyo": ("Hotels in Tokyo", "Had Hotels in Tokyo open in Safari."),
    ]
    func writeMomentNotes() throws {
        for m in try store.dayLayers(day: day, timezone: zone, now: now).activities where m.status != "ready" {
            let (title, text) = bullets[m.subject] ?? (m.subject, "Had \(m.subject) open.")
            let request = try store.prepareNote(kind: "activity", day: day, timezone: zone, activityID: m.id, now: now)
            _ = try store.commitNote(NoteWriterOutput(requestID: request.id, title: title, bullets: [NoteBullet(text: text, actionIDs: request.actions.map(\.id), assertion: "observed")],
                                                      generator: "local/synthetic", generatorVersion: "1"), now: now)
        }
    }
    try writeMomentNotes()
    let moments = try store.dayLayers(day: day, timezone: zone, now: now).activities
    try check(moments.count == 6 && moments.allSatisfy { $0.status == "ready" }, "levels fixture: six moments with notes")

    // MARK: blocks (L3)
    var work = try store.levelWork(timezone: zone, now: now)
    try check(work.map(\.level) == [.block, .block, .block] && work.map(\.children.count) == [3, 2, 1], "blocks cut at gaps over 30 minutes; days wait for their blocks")
    try check(work[2].codeOnly && !work[0].codeOnly, "a one-moment block is written by code")
    let a = work[0], b = work[1], c = work[2]
    // The line rules, as the model's full note meets them (weeks and months without threads, and every level before
    // threads): blocks and days now take the model's title only, and their lines are the code's thread bullets
    // (ThreadChecks), so these checks read the request as it was without its threads.
    func refused(_ raw: String, _ request: LevelRequest, _ code: String) -> Bool {
        var plain = request; plain.threads = nil
        do { _ = try LevelGrounding.validate(raw, request: plain); return false } catch let r as LevelGrounding.Reject { return r.code == code } catch { return false }
    }
    let goodA = #"{"goal":"fixing the export crash","lines":[{"ids":["m2"],"text":"Asked Claude to find why export crashes on big files."},{"ids":["m3"],"text":"Drafted an email to Priya about the export bug."}]}"#
    let validA = try LevelGrounding.validate(goodA, request: a)
    try check(validA.title == "About 45 minutes: fixing the export crash" && validA.lines.count == 2 && validA.lines[1].children == [a.children[2].ref.id], "block title: code-written span, model-written goal; lines link to their moments")
    // notes-quality: a side thread with a sent, asked or drafted line is that line; the rest, a name and minutes.
    try check(validA.lines.map(\.text) == ["Asked Claude to find why export crashes on big files.", "Drafted an email to Priya about the export bug."],
              "threads: the block's lines are its side threads, whatever the model wrote (\(validA.lines.map(\.text)))")
    try check(refused(#"{"goal":"fixing the export crash","lines":[{"ids":["m3"],"text":"Emailed Priya about the export bug."}]}"#, a, "verb"), "a block never upgrades a draft to a send (Drafted an email -> Emailed refused)")
    try check(refused(#"{"goal":"fixing the export crash","lines":[{"ids":["m2"],"text":"Fixed the export crash with a fix from Claude."}]}"#, a, "verb"), "a block never claims a fix no moment says")
    // The model's own lines are validated without threads (with threads a block's lines are its side threads).
    var plainA = a; plainA.threads = nil
    var fixReason = ""
    do { _ = try LevelGrounding.validate(#"{"goal":"fixing the export crash","lines":[{"ids":["m2"],"text":"Fixed the export crash."}]}"#, request: plainA) } catch let r as LevelGrounding.Reject { fixReason = r.reason }
    try check(fixReason.contains("\"worked on\" instead of \"fixed\""), "the repair turn names the honest verb to use (worked on, not fixed)")
    try check(refused(#"{"goal":"fixing the export crash","lines":[{"ids":["m2"],"text":"Finalized the export crash fix with Claude."}]}"#, a, "verb"), "an -ing goal is not an outcome (finalized refused)")
    var twoReason = ""
    do { _ = try LevelGrounding.validate(#"{"goal":"fixing the export crash","lines":[{"ids":["m2"],"text":"Fixed the crash and finalized the export."}]}"#, request: plainA) } catch let r as LevelGrounding.Reject { twoReason = r.reason }
    try check(twoReason.contains("\"fixed\" and \"finalized\""), "a refusal names every unsupported claim word at once")
    try check(refused(#"{"goal":"fixing the export crash","lines":[{"ids":["m2"],"text":"Asked Sam about the export crash."}]}"#, a, "name"), "names must be in the cited moments")
    try check(refused(#"{"goal":"fixing the export crash","lines":[{"ids":["m1"],"text":"Asked Claude about the export crash."}]}"#, a, "name") == false, "Claude is always nameable")
    try check(refused(#"{"goal":"fixing the export crash","lines":[{"ids":["m3"],"text":"Drafted an email to Priya; they want 3 fixes."}]}"#, a, "number") || refused(#"{"goal":"fixing the export crash","lines":[{"ids":["m3"],"text":"Drafted an email to Priya; they want 3 fixes."}]}"#, a, "they"), "no numbers or they the moments don't have")
    try check(refused(#"{"goal":"fixing the export crash","lines":[{"ids":["m2"],"text":"The user asked Claude about the export crash."}]}"#, a, "user"), "never \"the user\"")
    try check(refused(#"{"goal":"fixing the export crash","lines":[{"ids":["m2"],"text":"Spent an hour asking Claude about the crash."}]}"#, a, "duration"), "no time spent")
    try check(refused(#"{"goal":"fixing the export crash","lines":[{"ids":["m9"],"text":"Asked Claude about the crash."}]}"#, a, "ids"), "lines cite ids from the list")
    try check(refused(#"{"goal":"Export crash","lines":[{"ids":["m2"],"text":"Asked Claude about the crash."}]}"#, a, "goal"), "the goal is an -ing phrase")
    try check(refused(#"{"goal":"fixing the export crash","lines":[{"ids":["m2"],"text":"Asked Claude about m2."}]}"#, a, "alias"), "no ids in the text")
    try store.commitLevel(a, title: validA.title, lines: validA.lines, generator: "local/synthetic", now: now)
    let validB = try LevelGrounding.validate(#"{"goal":"planning the Tokyo trip","lines":[{"ids":["m1","m2"],"text":"Looked at flights to Tokyo and wrote a packing list for the trip."}]}"#, request: b)
    let noteB = try store.commitLevel(b, title: validB.title, lines: validB.lines, generator: "local/synthetic", now: now)
    try check(noteB.typedDerived && noteB.children.count == 2 && noteB.actionIDs.contains("b2-2"), "a block from a typed moment is marked typed-derived and keeps its actions")
    let extC = LevelGrounding.extractive(c)
    let noteC = try store.commitLevel(c, title: extC.title, lines: extC.lines, generator: LevelWriterVersion.extractive, now: now)
    try check(noteC.title == "A few minutes: Evening playlist" && noteC.lines.map(\.text) == ["Had Evening playlist open in Music."],
              "code-written one-moment block: its moment's title and its own line (\(noteC.title))")
    var tampered = extC.lines; tampered[0].text = "Finished the playlist."
    try check(LevelGrounding.check(title: extC.title, lines: tampered, request: c, extractive: true) == "threads", "a code-written line must be the code's own line")
    var blocked = false
    do { try store.commitLevel(a, title: validA.title, lines: [LevelLine(text: "Emailed Priya about the export bug.", children: [a.children[2].ref.id])], generator: "local/synthetic", now: now) } catch { blocked = true }
    try check(blocked, "core re-checks every level line before saving")

    // MARK: day, week, month (L4, L5)
    work = try store.levelWork(timezone: zone, now: now)
    try check(work.first?.level == .day && work.first?.children.count == 3 && work.first?.children.map(\.alias) == ["b1", "b2", "b3"], "the day is written from its blocks once they are all written")
    let dayRequest = work[0]
    let dayRaw = #"{"headline":"Worked on the export crash and planned the Tokyo trip","lines":[{"ids":["b1"],"text":"Asked Claude to find why export crashes on big files."},{"ids":["b2"],"text":"Planned the Tokyo trip and wrote a packing list."}]}"#
    let dayValid = try LevelGrounding.validate(dayRaw, request: dayRequest)
    // The model's own lines, checked without threads (a threaded day's lines are its threads' bullets).
    var plainDay = dayRequest; plainDay.threads = nil
    // Lines grounded in the (thread-written) blocks b1-b3; the sixth and seventh are past the limit and never checked.
    let many = try LevelGrounding.validate(#"{"headline":"Worked on the export crash","lines":[{"ids":["b1"],"text":"Worked on the export crash."},{"ids":["b1"],"text":"Wrote about the export bug."},{"ids":["b2"],"text":"Worked on the Tokyo trip."},{"ids":["b3"],"text":"Had Evening playlist open in Music."},{"ids":["b1","b2"],"text":"Worked on the export crash and the Tokyo trip."},{"ids":["b1"],"text":"Worked on the export crash again."},{"ids":["b1"],"text":"Fixed everything."}]}"#, request: plainDay)
    try check(many.lines.count == 5, "an answer with too many lines keeps the first five (each still checked)")
    try check(refused(#"{"headline":"Shipped the export fix and booked Tokyo","lines":[{"ids":["b1"],"text":"Asked Claude about the crash."}]}"#, dayRequest, "verb"), "a day never claims what no block says (shipped)")
    let dayNote = try store.commitLevel(dayRequest, title: dayValid.title, lines: dayValid.lines, generator: "local/synthetic", now: now)
    try check(dayNote.typedDerived && dayNote.title == "Worked on the export crash and planned the Tokyo trip.", "day note saved; typed-derived passes up")
    work = try store.levelWork(timezone: zone, now: now)
    try check(work.first?.level == .week && work.first?.period == "2027-W02", "the week is written from its days")
    // fix/sx-all round 1: the main-thread rule for weeks: a headline that is one of the day's side lines is refused, and a
    // week of one day is written by code with that day's headline.
    try check(refused(#"{"headline":"Asked Claude to find why export crashes on big files","lines":[{"ids":["d1"],"text":"Planned the Tokyo trip and wrote a packing list."}]}"#, work[0], "headline"),
              "a week headline that repeats one side line of its day is refused")
    try check(work[0].codeOnly && LevelGrounding.extractive(work[0]).title != "Asked Claude to find why export crashes on big files.", "a one-day week is written by code, from its main thread (\(LevelGrounding.extractive(work[0]).title))")
    var threadedSide = work[0]; if threadedSide.threads == nil { threadedSide.threads = [] }
    do { _ = try LevelGrounding.validate(#"{"headline":"Asked Claude to find why export crashes on big files"}"#, request: work[0]); try check(false, "a threaded week headline that repeats a side line is refused") }
    catch let r as LevelGrounding.Reject { try check(r.code == "headline", "a threaded week headline that repeats a side line is refused (\(r.code))") }
    _ = threadedSide
    let weekValid = try LevelGrounding.validate(#"{"headline":"A week on the export crash and the Tokyo trip","lines":[{"ids":["d1"],"text":"Asked Claude to find why export crashes on big files."}]}"#, request: work[0])
    try store.commitLevel(work[0], title: weekValid.title, lines: weekValid.lines, generator: "local/synthetic", now: now)
    work = try store.levelWork(timezone: zone, now: now)
    try check(work.first?.level == .month && work.first?.period == "2027-01", "the month is written from its weeks")
    // The headline rule of the plain extractive path (a threaded month's code title is its main thread's name).
    var plainMonth = work[0]; plainMonth.threads = nil
    let monthExt = LevelGrounding.extractive(plainMonth)
    try check(monthExt.title == "A week on the export crash and the Tokyo trip.", "a code-written parent keeps a child's headline as it is (never \"Mostly Mostly\" or \"Mostly Asked\")")
    try check(LevelGrounding.extractive(plainDay).title == "Mostly fixing the export crash.", "a code-written day reads \"Mostly\" plus its biggest block's goal")
    let monthNote = LevelGrounding.extractive(work[0])
    try store.commitLevel(work[0], title: monthNote.title, lines: monthNote.lines, generator: LevelWriterVersion.extractive, now: now)
    try check(try store.levelWork(timezone: zone, now: now).isEmpty, "nothing waits once every level is written")

    // MARK: recall (MCP): zoom and drill down, search every level
    func object(_ text: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:] }
    let week = object(try store.assistantRecall(level: "week", when: day, open: nil, query: nil, timezone: zone, now: now))
    let weekKids = week["children"] as? [[String: Any]] ?? []
    try check(week["title"] as? String == weekValid.title && weekKids.first?["open"] as? String == "day:" + day, "recall week: its note and a handle to each day")
    let dayNode = object(try store.assistantRecall(level: nil, when: nil, open: "day:" + day, query: nil, timezone: zone, now: now))
    let blockKids = dayNode["children"] as? [[String: Any]] ?? []
    try check(blockKids.count == 3 && (blockKids.first?["title"] as? String) == validA.title, "drill: day -> its blocks")
    let blockNode = object(try store.assistantRecall(level: nil, when: nil, open: blockKids[0]["open"] as? String, query: nil, timezone: zone, now: now))
    let momentKids = blockNode["children"] as? [[String: Any]] ?? []
    try check(momentKids.count == 3 && (momentKids[2]["title"] as? String) == "Export bug", "drill: block -> its moments")
    let momentNode = object(try store.assistantRecall(level: nil, when: nil, open: momentKids[2]["open"] as? String, query: nil, timezone: zone, now: now))
    let lineKids = momentNode["lines"] as? [[String: Any]] ?? []
    try check(lineKids.first?["text"] as? String == "Drafted an email to Priya about the export bug." && (lineKids.first?["when"] as? String ?? "").contains("9:40"), "drill: moment -> its lines, each with its time")
    let afternoon = object(try store.assistantRecall(level: "block", when: "thursday afternoon", open: nil, query: nil, timezone: zone, now: now))
    try check((afternoon["blocks"] as? [[String: Any]])?.map { $0["title"] as? String ?? "" } == [validB.title], "recall block for \"thursday afternoon\" gives only that stretch")
    let found = object(try store.assistantRecall(level: nil, when: nil, open: nil, query: "email export", timezone: zone, now: now))
    let hits = found["hits"] as? [[String: Any]] ?? []
    try check(Set(hits.compactMap { $0["level"] as? String }).isSuperset(of: ["line", "block"]) && hits.allSatisfy { ($0["when"] as? String ?? "") != "" && $0["open"] != nil }, "search every level: word starts match (email -> an email), each hit with level, time and handle")
    let tiers = hits.map { ["line": 0, "moment": 1, "block": 1][$0["level"] as? String ?? ""] ?? 2 }
    try check(hits.first?["level"] as? String == "line" && tiers == tiers.sorted(), "search lists the most specific hits first (lines, then moments and blocks, then days and up)")
    let noteHits = try store.noteHits(query: "email Priya", now: now)
    try check(noteHits.contains { $0["level"] as? String == "line" && ($0["text"] as? String ?? "").contains("Priya") }, "N12: the search tool's note hits find a send line by word starts")
    try check(object(try store.assistantRecall(level: nil, when: nil, open: nil, query: "passport", timezone: zone, now: now))["hits"] as? [Any] == nil || (object(try store.assistantRecall(level: nil, when: nil, open: nil, query: "passport", timezone: zone, now: now))["hits"] as? [Any])?.isEmpty == true, "typed words are never searchable through recall")

    // MARK: growth: a new moment makes its block, then the day, stale
    _ = try store.ingest(window("b3-1", 14, 40, "Safari", "com.apple.Safari", "Hotels in Tokyo"), now: now)
    work = try store.levelWork(timezone: zone, now: now)
    try check(!work.contains { $0.level == .day }, "a stretch with a moment still waiting for its note holds its day")
    try writeMomentNotes()
    work = try store.levelWork(timezone: zone, now: now)
    try check(work.first?.target == b.target && work.first?.children.count == 3, "a grown stretch is rebuilt under the same block id")
    let rebuilt = LevelGrounding.extractive(work[0])
    try store.commitLevel(work[0], title: rebuilt.title, lines: rebuilt.lines, generator: LevelWriterVersion.extractive, now: now)
    work = try store.levelWork(timezone: zone, now: now)
    try check(work.first?.level == .day, "then its day is stale and written again")
    var stale = false
    do { try store.commitLevel(dayRequest, title: dayValid.title, lines: dayValid.lines, generator: "local/synthetic", now: now) } catch { stale = true }
    try check(stale, "an old request for a grown day is refused")
    let dayAgain = LevelGrounding.extractive(work[0])
    try store.commitLevel(work[0], title: dayAgain.title, lines: dayAgain.lines, generator: LevelWriterVersion.extractive, now: now)

    // MARK: delete propagates up
    let weekID = work[0].target.replacingOccurrences(of: "lday_", with: "")   // unused shape guard
    _ = weekID
    let ids = (a: a.target, b: b.target, c: c.target)
    let dayID = dayRequest.target
    let weekNoteID = try store.allLevelNotes().first { $0.level == .week }!.id, monthNoteID = try store.allLevelNotes().first { $0.level == .month }!.id
    try store.delete("a2-1")
    try check(try store.levelNote(ids.a) == nil && store.levelNote(dayID) == nil && store.levelNote(weekNoteID) == nil && store.levelNote(monthNoteID) == nil,
              "deleting an action deletes its block and every note above it")
    try check(try store.levelNote(ids.b) != nil && store.levelNote(ids.c) != nil, "other blocks stay")
    let search = object(try store.assistantRecall(level: nil, when: nil, open: nil, query: "export crashes", timezone: zone, now: now))
    try check((search["hits"] as? [Any])?.isEmpty == true, "deleted content can't be found at any level")

    // MARK: backups: the level tables are expected, and never copied (levels are rebuilt from moment notes)
    let held = try store.allLevelNotes().count
    let copyHome = home.deletingLastPathComponent().appendingPathComponent(home.lastPathComponent + "-levels-backup")
    try? FileManager.default.removeItem(at: copyHome)
    let copy = try MemoryStore(home: copyHome, writable: true, automaticallySyncSearch: false)
    let audit = try store.exportCanonicalSnapshot(to: copy, now: now)
    try check(held > 0 && audit.counts["level_notes"] == nil && (try copy.allLevelNotes()).isEmpty, "a backup of a store with level notes works and copies none of them")
    try? FileManager.default.removeItem(at: copyHome)

    // MARK: retention freezes, Forget deletes typed-derived notes even when frozen
    try writeMomentNotes()
    while let next = try store.levelWork(timezone: zone, now: now).first {
        let x = LevelGrounding.extractive(next)
        try store.commitLevel(next, title: x.title, lines: x.lines, generator: LevelWriterVersion.extractive, now: now)
    }
    let rebuiltDay = try store.levelNote(dayID)
    let rebuiltWeek = try store.levelNote(weekNoteID)
    try check(rebuiltDay != nil && rebuiltDay!.typedDerived && rebuiltWeek != nil, "the day and week are rebuilt from what is left")
    _ = try store.writePending(now: now.addingTimeInterval(40 * 86400))
    let frozenDay = try store.levelNote(dayID), frozenWeek = try store.levelNote(weekNoteID)
    try check(try store.levelNote(ids.b) == nil && store.levelNote(ids.c) == nil, "history retention takes the blocks with their moments")
    try check(frozenDay?.frozen == true && frozenWeek != nil, "the day above expired blocks is frozen, not deleted; the week stays")
    try check(try store.levelWork(timezone: zone, now: now).allSatisfy { $0.target != dayID }, "a frozen note is never rebuilt")
    _ = try store.forgetTypedText(confirmed: true, now: now.addingTimeInterval(40 * 86400))
    try check(try store.levelNote(dayID) == nil && store.levelNote(weekNoteID) == nil, "Forget what I typed deletes typed-derived level notes, frozen or not")
    try runLevelForgetRaceChecks(home: home.appendingPathComponent("forget-race"))
    try runLevelTypedDraftChecks(home: home.appendingPathComponent("typed-draft"))
    print("Level checks use a synthetic store only. No model, capture or index.")
}

/// r1 forget-range: a Forget that commits on another connection after a level note's checks and before its write lock
/// (LevelCommitWindow) leaves no note written from the forgotten moments: the input is read again inside the lock.
func runLevelForgetRaceChecks(home: URL) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000), zone = "UTC", day = "2027-01-14"
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    let review = try store.prepareRetentionChange(.days(30), now: now)
    _ = try store.confirmRetentionChange(review.id, confirmed: true, now: now)
    func at(_ h: Int, _ m: Int) -> String { iso(try! DayScope.interval(day: day, timezone: zone).start.addingTimeInterval(Double(h * 3600 + m * 60))) }
    for (id, h, m, title) in [("r-x1", 9, 0, "ExportView.swift — tallybird"), ("r-x2", 9, 4, "ExportView.swift — tallybird"),
                              ("r-w1", 14, 0, "Walrus invoice"), ("r-w2", 14, 4, "Walrus invoice")] {
        let mail = title.hasPrefix("Walrus")
        _ = try store.ingest(Evidence(id: id, at: at(h, m), kind: "window.changed", app: mail ? "Mail" : "Xcode", bundle: mail ? "com.apple.mail" : "com.apple.dt.Xcode", title: title, synthetic: true), now: now)
    }
    for m in try store.dayLayers(day: day, timezone: zone, now: now).activities {
        let request = try store.prepareNote(kind: "activity", day: day, timezone: zone, activityID: m.id, now: now)
        let text = m.subject.hasPrefix("Walrus") ? "Read the Walrus invoice in Mail." : "Had ExportView.swift open in Xcode."
        _ = try store.commitNote(NoteWriterOutput(requestID: request.id, title: m.subject, bullets: [NoteBullet(text: text, actionIDs: request.actions.map(\.id), assertion: "observed")],
                                                  generator: "local/synthetic", generatorVersion: "1"), now: now)
    }
    let blocks = try store.levelWork(timezone: zone, now: now)
    guard blocks.count == 2, let walrus = blocks.first(where: { $0.actionIDs.contains("r-w1") }), let kept = blocks.first(where: { !$0.actionIDs.contains("r-w1") }) else {
        throw MemError.invalid("FAILED: forget race fixture: two blocks")
    }
    let other = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    // A block: the Forget lands in the window; nothing is saved from the forgotten moment.
    LevelCommitWindow.listen { try? other.delete("r-w1"); try? other.delete("r-w2") }
    let code = LevelGrounding.extractive(walrus)
    var refused = false
    do { try store.commitLevel(walrus, title: code.title, lines: code.lines, generator: LevelWriterVersion.extractive, now: now) } catch { refused = true }
    LevelCommitWindow.listen(nil)
    try check(refused && (try store.levelNote(walrus.target)) == nil, "forget race: a block whose moments are forgotten after its checks is not saved")
    try check(try !store.allLevelNotes().contains { n in n.title.contains("Walrus") || n.lines.contains { $0.text.contains("Walrus") } }, "forget race: no level note mentions the forgotten moment")
    // The kept block still saves; then a day whose block is forgotten in the window is not saved either.
    let keptCode = LevelGrounding.extractive(kept)
    try store.commitLevel(kept, title: keptCode.title, lines: keptCode.lines, generator: LevelWriterVersion.extractive, now: now)
    guard let dayRequest = try store.levelWork(timezone: zone, now: now).first(where: { $0.level == .day }) else { throw MemError.invalid("FAILED: forget race: the day waits") }
    LevelCommitWindow.listen { try? other.delete("r-x1") }
    let dayCode = LevelGrounding.extractive(dayRequest)
    refused = false
    do { try store.commitLevel(dayRequest, title: dayCode.title, lines: dayCode.lines, generator: LevelWriterVersion.extractive, now: now) } catch { refused = true }
    LevelCommitWindow.listen(nil)
    try check(refused && (try store.levelNote(dayRequest.target)) == nil && (try store.levelNote(kept.target)) == nil,
              "forget race: a day whose block is forgotten after its checks is not saved (and the block went with its action)")
}

/// r1 levels-pipeline: a page named after the short draft typed into it ("fix my resume" -> "Fix my resume": a chat's
/// page title, or a note Notes names by its first line) gives a
/// code-written block title that repeats the draft, which core refuses. The plain note (no window-title names) is
/// accepted instead, and levelWork passes over a request the writer could not save, so it holds nothing else.
func runLevelTypedDraftChecks(home: URL) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000), zone = "UTC", day = "2027-01-14"
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    let review = try store.prepareRetentionChange(.days(30), now: now)
    _ = try store.confirmRetentionChange(review.id, confirmed: true, now: now)
    var consent = try store.policy(); consent.captureText = true; consent.typedConsentVersion = 1; try store.updatePolicy(consent, now: now)
    try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore()), now: now); try store.setUpTypedVault(now: now)
    try store.acceptSafeTyping(now: now)
    func at(_ h: Int, _ m: Int) -> String { iso(try! DayScope.interval(day: day, timezone: zone).start.addingTimeInterval(Double(h * 3600 + m * 60))) }
    let claude = ("Notes", "com.apple.Notes")
    let events = [
        Evidence(id: "t-new", at: at(9, 0), kind: "window.changed", app: claude.0, bundle: claude.1, title: "New Note", synthetic: true),
        Evidence(id: "t-typed", at: at(9, 1), kind: "keyboard.text_input", app: claude.0, bundle: claude.1, title: "New Note", text: "fix my resume", synthetic: true),
        Evidence(id: "t-w1", at: at(9, 3), kind: "window.changed", app: claude.0, bundle: claude.1, title: "Fix my resume", synthetic: true),
        Evidence(id: "t-w2", at: at(9, 7), kind: "window.changed", app: claude.0, bundle: claude.1, title: "Fix my resume", synthetic: true),
        Evidence(id: "t-w3", at: at(9, 12), kind: "window.changed", app: claude.0, bundle: claude.1, title: "Fix my resume", synthetic: true),
        Evidence(id: "t-m1", at: at(9, 15), kind: "window.changed", app: "Messages", bundle: "com.apple.MobileSMS", title: "Maya", synthetic: true),
        Evidence(id: "t-m2", at: at(9, 18), kind: "window.changed", app: "Messages", bundle: "com.apple.MobileSMS", title: "Maya", synthetic: true),
        Evidence(id: "t-w4", at: at(9, 20), kind: "window.changed", app: claude.0, bundle: claude.1, title: "Fix my resume", synthetic: true),
        // r2: the same note reopened in the afternoon, typing nothing: its own block keeps the window title, and it is
        // the day's longest stretch of that thread (so a day merged from raw names would headline the draft).
        Evidence(id: "t-p1", at: at(14, 0), kind: "window.changed", app: claude.0, bundle: claude.1, title: "Fix my resume", synthetic: true),
        Evidence(id: "t-p2", at: at(14, 10), kind: "window.changed", app: claude.0, bundle: claude.1, title: "Fix my resume", synthetic: true),
        Evidence(id: "t-p3", at: at(14, 20), kind: "window.changed", app: claude.0, bundle: claude.1, title: "Fix my resume", synthetic: true),
        Evidence(id: "t-p4", at: at(14, 30), kind: "window.changed", app: claude.0, bundle: claude.1, title: "Fix my resume", synthetic: true),
        Evidence(id: "t-p5", at: at(14, 40), kind: "window.changed", app: claude.0, bundle: claude.1, title: "Fix my resume", synthetic: true),
    ]
    for e in events { _ = try store.ingest(e, now: now) }
    for m in try store.dayLayers(day: day, timezone: zone, now: now).activities {
        let request = try store.prepareNote(kind: "activity", day: day, timezone: zone, activityID: m.id, now: now)
        let (title, text) = m.apps.contains("Messages") ? ("Texts with Maya", "Had a chat with Maya open in Messages.") : ("Notes", "Wrote a note in Notes.")
        _ = try store.commitNote(NoteWriterOutput(requestID: request.id, title: title, bullets: [NoteBullet(text: text, actionIDs: request.actions.map(\.id), assertion: "observed")],
                                                  generator: "local/synthetic", generatorVersion: "1"), now: now)
    }
    let work = try store.levelWork(timezone: zone, now: now)
    guard let block = work.first(where: { $0.level == .block && $0.actionIDs.contains("t-typed") }) else { throw MemError.invalid("FAILED: typed draft fixture: a block covers the typed row") }
    let code = LevelGrounding.extractive(block)
    try check(code.title.hasSuffix(": Fix my resume"), "typed draft fixture: the code's block title is the note's window title (\(code.title))")
    var refusal = ""
    do { try store.commitLevel(block, title: code.title, lines: code.lines, generator: LevelWriterVersion.extractive, now: now) } catch MemError.invalid(let m) { refusal = m }
    try check(refusal == MemoryStore.typedCopyRefusal, "a code-written block title that repeats a short typed draft is refused (typed words are write-only)")
    // The next pass must not meet the same refused block first, and the block doesn't hold its day forever.
    try check(try !store.levelWork(timezone: zone, now: now, skipping: [MemoryStore.workKey(block)]).contains { $0.target == block.target },
              "levelWork passes over a request the writer could not save")
    let plain = LevelGrounding.plainThreadNote(block)
    try check(!plain.title.lowercased().contains("resume") && plain.lines.allSatisfy { !$0.text.lowercased().contains("resume") } && plain.title.hasSuffix(": Document"),
              "the plain note names no window title: \(plain.title) | \(plain.lines.map(\.text))")
    try check(plain.lines.map(\.text).allSatisfy { !$0.contains("Maya") } && plain.lines.map(\.text) == ["Texts, ~5 min"], "the plain note's side threads are plain too (Texts), and none repeats the title")
    let saved = try store.commitLevel(block, title: plain.title, lines: plain.lines, generator: LevelWriterVersion.extractive, now: now)
    try check(saved.title == plain.title && (try store.levelNote(block.target)) != nil, "core accepts the plain code-written note, so the day's summaries go on")
    try check(LevelGrounding.check(title: plain.title, lines: plain.lines, request: block, extractive: false) == "threads", "only code may write the plain note (a model's note keeps the code's bullets)")
    // r2: the plain block keeps plain thread names, so nothing merged from it (or read by AI apps) names the draft.
    let stored = try store.levelNote(block.target)
    let names = (stored?.threads ?? []).flatMap { [$0.label] + $0.people + $0.places }
    try check(!names.isEmpty && names.allSatisfy { !$0.lowercased().contains("resume") && !$0.contains("Maya") }, "r2: a block saved plain stores plain thread names, the ones AI apps read (\(names))")
    // The afternoon block (no typing in it) is saved as usual, window title and all.
    guard let afternoon = try store.levelWork(timezone: zone, now: now).first(where: { $0.level == .block && !$0.actionIDs.contains("t-typed") }) else {
        throw MemError.invalid("FAILED: typed draft fixture: the afternoon block is asked for")
    }
    let pm = LevelGrounding.extractive(afternoon)
    _ = try store.commitLevel(afternoon, title: pm.title, lines: pm.lines, generator: LevelWriterVersion.extractive, now: now)
    guard let dayRequest = try store.levelWork(timezone: zone, now: now).first(where: { $0.level == .day && $0.period == day }) else {
        throw MemError.invalid("FAILED: then the day is written")
    }
    // r2: the day runs the typed check over the blocks' typed rows: a day headline that repeats the draft is refused, and
    // the plain day note is saved, with plain thread names (they reach the week and month, and AI apps).
    let dayCode = LevelGrounding.extractive(dayRequest)
    var dayRefusal = ""
    do { try store.commitLevel(dayRequest, title: dayCode.title, lines: dayCode.lines, generator: LevelWriterVersion.extractive, now: now) } catch MemError.invalid(let m) { dayRefusal = m }
    try check(dayCode.title.lowercased().contains("resume") && dayRefusal == MemoryStore.typedCopyRefusal,
              "r2: a day headline that repeats a short typed draft is refused, as a block's is (\(dayCode.title): \(dayRefusal))")
    let plainDay = LevelGrounding.plainThreadNote(dayRequest)
    let savedDay = try store.commitLevel(dayRequest, title: plainDay.title, lines: plainDay.lines, generator: LevelWriterVersion.extractive, now: now)
    let dayNames = [savedDay.title] + savedDay.lines.map(\.text) + (savedDay.threads ?? []).flatMap { [$0.label] + $0.people + $0.places }
    try check(dayNames.allSatisfy { !$0.lowercased().contains("resume") }, "r2: the plain day note and its threads name no typed draft (\(dayNames))")
}

/// r2 (launch review): a moment whose note is still pending (waiting for Retry: a grounding failure, a cloud error) holds
/// only its own block, and only for a day. After that its block and its day are written without it, so one stuck
/// moment never stops the summaries (the app no longer gates levels on pending notes either: notes-writer-checks).
func runLevelPendingMomentChecks(home: URL) throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000), zone = "UTC", day = "2027-01-14"   // now: 2027-01-15 08:00 UTC
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    let review = try store.prepareRetentionChange(.days(30), now: now)
    _ = try store.confirmRetentionChange(review.id, confirmed: true, now: now)
    func at(_ h: Int, _ m: Int) -> String { iso(try! DayScope.interval(day: day, timezone: zone).start.addingTimeInterval(Double(h * 3600 + m * 60))) }
    let events = [
        Evidence(id: "p-x1", at: at(9, 0), kind: "window.changed", app: "Xcode", bundle: "com.apple.dt.Xcode", title: "ExportView.swift — tallybird", synthetic: true),
        Evidence(id: "p-x2", at: at(9, 4), kind: "window.changed", app: "Xcode", bundle: "com.apple.dt.Xcode", title: "ExportView.swift — tallybird", synthetic: true),
        Evidence(id: "p-s1", at: at(9, 10), kind: "window.changed", app: "Safari", bundle: "com.apple.Safari", title: "Flights to Tokyo", synthetic: true),
        Evidence(id: "p-s2", at: at(9, 14), kind: "window.changed", app: "Safari", bundle: "com.apple.Safari", title: "Flights to Tokyo", synthetic: true),
        Evidence(id: "p-n1", at: at(9, 20), kind: "window.changed", app: "Music", bundle: "com.apple.Music", title: "Evening playlist", synthetic: true),
        Evidence(id: "p-n2", at: at(9, 24), kind: "window.changed", app: "Music", bundle: "com.apple.Music", title: "Evening playlist", synthetic: true),
    ]
    for e in events { _ = try store.ingest(e, now: now) }
    let moments = try store.dayLayers(day: day, timezone: zone, now: now).activities
    try check(moments.count >= 2, "pending-moment fixture: the day has several moments (\(moments.count))")
    // Every moment but the last gets its note; the last stays pending (never written).
    let stuck = moments.max { $0.start < $1.start }!
    for m in moments where m.id != stuck.id {
        let request = try store.prepareNote(kind: "activity", day: day, timezone: zone, activityID: m.id, now: now)
        _ = try store.commitNote(NoteWriterOutput(requestID: request.id, title: m.subject, bullets: [NoteBullet(text: "Had \(m.subject) open.", actionIDs: request.actions.map(\.id), assertion: "observed")],
                                                  generator: "local/synthetic", generatorVersion: "1"), now: now)
    }
    try check(try !store.levelWork(timezone: zone, now: now).contains { $0.level == .block && $0.period == day },
              "a moment still pending less than a day after it ended holds its block (its note may still come)")
    let later = now.addingTimeInterval(3 * 3600)   // over a day after the stuck moment ended
    guard let block = try store.levelWork(timezone: zone, now: later).first(where: { $0.level == .block && $0.period == day }) else {
        throw MemError.invalid("FAILED: a moment still pending a day after it ended no longer holds its block")
    }
    try check(!block.children.contains { $0.ref.id == stuck.id }, "the block is written without the pending moment")
    let b = LevelGrounding.extractive(block)
    _ = try store.commitLevel(block, title: b.title, lines: b.lines, generator: LevelWriterVersion.extractive, now: later)
    guard let dayRequest = try store.levelWork(timezone: zone, now: later).first(where: { $0.level == .day && $0.period == day }) else {
        throw MemError.invalid("FAILED: with a moment still pending, the day note is asked for once its blocks are written")
    }
    let d = LevelGrounding.extractive(dayRequest)
    let dayNote = try store.commitLevel(dayRequest, title: d.title, lines: d.lines, generator: LevelWriterVersion.extractive, now: later)
    try check(dayNote.level == .day && (try store.levelNote(dayRequest.target)) != nil, "r2: a pending moment still lets its day's block and day notes be written")
}
