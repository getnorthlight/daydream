import Foundation
import MemoryCore

/// MCP `recap` (mcp-recap-1002): a few days come back pre-grouped (headline, up to five time blocks with their theme,
/// apps and signal lines, brief visits only counted) so an AI app answers in a short per-day shape. Synthetic store
/// only; nothing here is anyone's real history. With DAYDREAM_RECAP_SAMPLE=<dir>, writes the before (day overviews)
/// and after (recap) replies there for review.
func runRecapChecks(home: URL) throws {
    let zone = "UTC"
    let now = Date(timeIntervalSince1970: 1_800_043_200)   // Fri 2027-01-15 20:00 UTC
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    let review = try store.prepareRetentionChange(.days(30), now: now)
    _ = try store.confirmRetentionChange(review.id, confirmed: true, now: now)
    var consent = try store.policy(); consent.captureText = true; consent.typedConsentVersion = 1; try store.updatePolicy(consent, now: now)
    try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore()), now: now); try store.setUpTypedVault(now: now)
    try store.acceptSafeTyping(now: now)

    struct App { let name: String; let bundle: String }
    let claude = App(name: "Claude", bundle: "com.anthropic.claudefordesktop"), chatgpt = App(name: "ChatGPT", bundle: "com.openai.chat")
    let zed = App(name: "Zed", bundle: "dev.zed.Zed"), finder = App(name: "Finder", bundle: "com.apple.finder")
    let messages = App(name: "Messages", bundle: "com.apple.MobileSMS"), music = App(name: "Music", bundle: "com.apple.Music")
    let linkedin = App(name: "LinkedIn", bundle: "com.example.linkedin"), canvas = App(name: "Canvas Student", bundle: "com.example.canvas")
    let homeworkHub = App(name: "Homework Hub", bundle: "com.example.homeworkhub"), notes = App(name: "Notes", bundle: "com.apple.Notes")
    var events = [Evidence](), serial = 0
    /// Bullets per window title: (note title, line, assertion).
    var notesFor = [String: (String, String, String)]()
    func at(_ day: String, _ h: Int, _ m: Int, _ s: Int = 0) -> String {
        iso(try! DayScope.interval(day: day, timezone: zone).start.addingTimeInterval(Double(h * 3600 + m * 60 + s)))
    }
    /// One window in front for `minutes`, one action a minute (so its focus is about that long).
    func session(_ day: String, _ h: Int, _ m: Int, _ minutes: Int, _ app: App, _ title: String, note: (String, String, String)? = nil) {
        for k in 0...max(0, minutes) {
            serial += 1
            events.append(Evidence(id: "r\(serial)", at: at(day, h, m + k), kind: "window.changed", app: app.name, bundle: app.bundle, title: title, synthetic: true))
        }
        if let note { notesFor[title] = note }
    }
    /// A glance: one action, nothing after it for a while.
    func glance(_ day: String, _ h: Int, _ m: Int, _ app: App, _ title: String) {
        serial += 1
        events.append(Evidence(id: "r\(serial)", at: at(day, h, m), kind: "window.changed", app: app.name, bundle: app.bundle, title: title, synthetic: true))
    }

    // Thu 2027-01-14: an evening of startup work, a late block, and brief visits that are noise.
    let thu = "2027-01-14", fri = "2027-01-15"
    session(thu, 18, 0, 25, claude, "Moving docs to Notion", note: ("Moving docs to Notion", "Asked Claude how to move the team docs to Notion.", "observed"))
    session(thu, 18, 26, 20, music, "Lofi study tracks", note: ("Lofi study tracks", "Looked up lofi study tracks and small venues.", "observed"))
    glance(thu, 19, 10, linkedin, "Feed")
    glance(thu, 22, 25, chatgpt, "New chat")
    glance(thu, 22, 50, finder, "Downloads")
    session(thu, 23, 20, 20, chatgpt, "Startup credits", note: ("Startup credits", "Asked ChatGPT about startup credits and demo feedback.", "observed"))
    session(thu, 23, 41, 18, zed, "index.html — tallybird-site", note: ("Tallybird site", "Worked on the Tallybird site landing page.", "observed"))
    // Fri 2027-01-15: after midnight, scattered 4 AM check-ins (noise), an afternoon of classes with a text.
    session(fri, 0, 5, 20, chatgpt, "Startup deals", note: ("Startup deals", "Read startup deals and cloud credits.", "observed"))
    session(fri, 0, 26, 12, finder, "Tallybird 2.3 test", note: ("Tallybird 2.3 test folders", "Organized the Tallybird 2.3 test folders.", "observed"))
    glance(fri, 4, 2, chatgpt, "New chat"); glance(fri, 4, 31, chatgpt, "New chat"); glance(fri, 5, 3, linkedin, "Notifications")
    session(fri, 14, 0, 15, canvas, "Biology 101 Announcements", note: ("Biology 101 announcements", "Read the Biology 101 announcements.", "observed"))
    session(fri, 14, 16, 12, canvas, "Art History Announcements", note: ("Art History", "Read the Art History announcements.", "observed"))
    session(fri, 14, 29, 7, homeworkHub, "Homework Hub - Assignment 4", note: ("Homework Hub assignment", "Worked on Homework Hub assignment 4.", "observed"))
    session(fri, 14, 37, 8, messages, "Jordan", note: ("Texts with Jordan", "Read texts from Jordan about dinner plans.", "observed"))
    serial += 1
    events.append(Evidence(id: "r-typed", at: at(fri, 14, 40, 30), kind: "keyboard.text_input", app: "Messages", bundle: messages.bundle, title: "Jordan",
                           text: "quokkamarmalade picnic at seven", synthetic: true))
    // Mon 2027-01-11: only brief visits. Tue 2027-01-12: one busy three-hour block. Wed 2027-01-13: nothing.
    glance("2027-01-11", 9, 0, linkedin, "Feed"); glance("2027-01-11", 13, 0, finder, "Desktop"); glance("2027-01-11", 18, 0, chatgpt, "New chat")
    let busy = "2027-01-12"
    for i in 0..<30 {
        let app = [zed, claude, notes][i % 3]
        let title = ["SyncEngine.swift — tallybird", "Sync conflict \(i / 3)", "Sync design notes"][i % 3]
        let note = [("SyncEngine code", "Worked on SyncEngine.swift in tallybird.", "observed"),
                    ("Sync conflict", "Asked Claude about sync conflict case \(i / 3).", "observed"),
                    ("Sync design notes", "Wrote the sync design notes.", "observed")][i % 3]
        session(busy, 9, i * 6, 5, app, title, note: note)
    }
    // Sat 2027-01-09 and Sun 2027-01-10: dense days with long notes, for the size bound.
    for day in ["2027-01-09", "2027-01-10"] {
        for b in 0..<12 {
            let h = 6 + b, label = "Long project \(day) \(b)"
            session(day, h, 0, 9, [zed, claude, chatgpt, notes][b % 4], label + " part A",
                    note: (label, "Asked \(["Claude", "ChatGPT"][b % 2]) a long question about \(label) with many extra words to make this line run long, longer than most lines.", "observed"))
            session(day, h, 10, 9, [notes, zed, finder, music][b % 4], label + " part B",
                    note: (label + " B", "Wrote a long section of the \(label) plan with even more words so that the line is long enough to be trimmed somewhere.", "observed"))
        }
    }
    for e in events { _ = try store.ingest(e, now: now) }
    func writeMomentNotes(_ day: String) throws {
        for m in try store.dayLayers(day: day, timezone: zone, now: now).activities where m.status != "ready" {
            guard let (title, text, assertion) = notesFor[m.subject] else { continue }
            let request = try store.prepareNote(kind: "activity", day: day, timezone: zone, activityID: m.id, now: now)
            _ = try store.commitNote(NoteWriterOutput(requestID: request.id, title: title, bullets: [NoteBullet(text: text, actionIDs: request.actions.map(\.id), assertion: assertion)],
                                                      generator: "local/synthetic", generatorVersion: "1"), now: now)
        }
    }
    for day in ["2027-01-09", "2027-01-10", "2027-01-11", busy, "2027-01-13", thu, fri] { try writeMomentNotes(day) }
    // Thursday's blocks are written (by code, as with summaries on a slow Mac); the rest keep the live threads' names.
    for work in try store.levelWork(timezone: zone, now: now, limit: 100) where work.level == .block && work.period == thu {
        let note = LevelGrounding.extractive(work)
        try store.commitLevel(work, title: note.title, lines: note.lines, generator: LevelWriterVersion.extractive, now: now)
    }
    try check(try store.dayLevels(day: thu, timezone: zone, now: now).blocks.count >= 2, "recap fixture: Thursday's blocks are written")

    func object(_ text: String) -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:] }
    func days(_ reply: [String: Any]) -> [[String: Any]] { reply["days"] as? [[String: Any]] ?? [] }
    func blocks(_ day: [String: Any]) -> [[String: Any]] { day["blocks"] as? [[String: Any]] ?? [] }

    // MARK: two days with noise
    let text = try store.assistantRecap(when: "past 2 days", timezone: zone, now: now)
    let recap = object(text)
    let two = days(recap)
    try check(two.map { $0["day"] as? String ?? "" } == ["Thu, Jan 14", "Fri, Jan 15"] && recap["range"] as? String == "Thu, Jan 14 to Fri, Jan 15",
              "recap past 2 days: one section per day, oldest first, with plain day names (\(two.map { $0["day"] ?? "" }))")
    try check(two.allSatisfy { ($0["headline"] as? String ?? "").isEmpty == false }, "recap: every busy day has a headline (\(two.map { $0["headline"] ?? "" }))")
    try check(two.flatMap(blocks).allSatisfy { b in let about = b["about"] as? String ?? ""; return !about.contains("minutes:") && !about.hasPrefix("About ") && !about.hasPrefix("A few") },
              "recap: a written block's theme is its goal, without the span prefix (\(two.flatMap(blocks).map { $0["about"] ?? "" }))")
    try check(!two.flatMap(blocks).flatMap { $0["did"] as? [String] ?? [] }.contains { $0.contains(", ~") },
              "recap: once moments have notes, thread names with minutes don't repeat them")
    try check(two.allSatisfy { (2...5).contains(blocks($0).count) }, "recap: 2-5 blocks a day (\(two.map { blocks($0).count }))")
    try check(two.flatMap(blocks).allSatisfy { ($0["did"] as? [String] ?? []).count <= 3 && !($0["when"] as? String ?? "").isEmpty && !($0["about"] as? String ?? "").isEmpty },
              "recap: each block has a when anchor, a theme and at most three lines")
    let thuBlocks = blocks(two[0]), friBlocks = blocks(two[1])
    try check(thuBlocks.first?["when"] as? String == "Evening" && (thuBlocks.first?["did"] as? [String])?.first == "Asked Claude how to move the team docs to Notion.",
              "recap: a block's sent or asked line comes first, under a part-of-day anchor (\(thuBlocks.first ?? [:]))")
    try check(thuBlocks.last?["when"] as? String == "Late evening" && (thuBlocks.last?["did"] as? [String] ?? []).contains("Asked ChatGPT about startup credits and demo feedback."),
              "recap: the late block keeps its ChatGPT ask (\(thuBlocks.last ?? [:]))")
    try check(friBlocks.first?["when"] as? String == "After midnight" && friBlocks.last?["when"] as? String == "Afternoon"
              && (friBlocks.last?["did"] as? [String] ?? []).contains("Read the Biology 101 announcements."),
              "recap: Friday reads after midnight, then the afternoon of classes (\(friBlocks))")
    // Friday: three glances, plus the unsent Messages draft as its own short moment where typing in Messages is
    // recorded (the owner build); it has no note, so it is counted, and its words never show.
    try check(two[0]["left_out"] as? String == "3 brief visits" && ["3 brief visits", "4 brief visits"].contains(two[1]["left_out"] as? String ?? ""),
              "recap: brief visits and noise are counted, not listed (\(two.map { $0["left_out"] ?? "" }))")
    try check(!text.contains("LinkedIn") && !text.contains("New chat") && !text.contains("Downloads") && !text.contains("Notifications"),
              "recap: no brief visit is named anywhere in the reply")
    try check(!text.contains("quokkamarmalade") && !text.contains("picnic"), "recap: never carries typed words")
    try check(!text.contains("macmem://") && !text.contains("com.") && !text.contains("activity_") && !text.contains("\"id\""),
              "recap: no links, bundle ids or ids")
    let everyWhen = two.flatMap(blocks).compactMap { $0["when"] as? String }
    try check(everyWhen.allSatisfy { !$0.contains(", ") } && two.flatMap(blocks).allSatisfy { b in (b["did"] as? [String] ?? []).allSatisfy { !$0.contains(" AM") && !$0.contains(" PM") } },
              "recap: times only as block anchors, never inside the lines")
    try check((recap["present"] as? String ?? "").contains("one plain line") && (recap["present"] as? String ?? "").contains("At most one short caveat, at the end"),
              "recap: the reply tells the reading model the answer shape")
    try check(object(try store.assistantRecap(when: "past couple days", timezone: zone, now: now))["range"] as? String == recap["range"] as? String
              && days(object(try store.assistantRecap(when: "yesterday", timezone: zone, now: now))).map { $0["date"] as? String ?? "" } == [thu]
              && days(object(try store.assistantRecap(when: "2027-01-13 to 2027-01-15", timezone: zone, now: now))).count == 3,
              "recap: when reads past couple days, yesterday and a date range")
    var unread = false
    do { _ = try store.assistantRecap(when: "next fortnight please", timezone: zone, now: now) } catch { unread = "\(error)".contains("past 2 days") }
    try check(unread, "recap: unreadable time words get a plain error with examples")

    // MARK: a quiet day, and a day of only brief visits
    let quiet = days(object(try store.assistantRecap(when: "2027-01-13", timezone: zone, now: now))).first ?? [:]
    try check(quiet["quiet"] as? String == "Nothing recorded." && quiet["blocks"] == nil && quiet["headline"] == nil && quiet["day"] as? String == "Wed, Jan 13",
              "recap: a quiet day says so in one field (\(quiet))")
    let glances = days(object(try store.assistantRecap(when: "2027-01-11", timezone: zone, now: now))).first ?? [:]
    try check(glances["quiet"] as? String == "Only brief visits." && glances["left_out"] as? String == "3 brief visits" && glances["blocks"] == nil,
              "recap: a day of only brief visits is quiet, its visits counted (\(glances))")

    // MARK: one busy block
    let busyDay = days(object(try store.assistantRecap(when: busy, timezone: zone, now: now))).first ?? [:]
    let busyBlocks = blocks(busyDay)
    try check((1...2).contains(busyBlocks.count) && busyBlocks.allSatisfy { ($0["did"] as? [String] ?? []).count <= 3 && ($0["apps"] as? [String] ?? []).count <= 4 },
              "recap: a three-hour run of thirty moments stays one or two blocks with at most three lines (\(busyBlocks.count))")
    let busyLines = busyBlocks.flatMap { $0["did"] as? [String] ?? [] }
    try check(busyLines.first?.hasPrefix("Asked Claude about sync conflict") == true && busyLines.filter { $0.hasPrefix("Asked Claude about sync conflict") }.count == 1
              && busyLines.contains("Wrote the sync design notes."),
              "recap: the busy block leads with an ask, says it once (not once per number), then the other work (\(busyLines))")

    // MARK: size bound
    let week = try store.assistantRecap(when: "past 7 days", timezone: zone, now: now)
    let weekDays = days(object(week))
    try check(week.utf8.count <= MemoryStore.recapMaxBytes && weekDays.count == 7, "recap: seven days, two of them dense, fit in \(MemoryStore.recapMaxBytes) bytes (\(week.utf8.count))")
    try check(weekDays.allSatisfy { blocks($0).count <= 5 } && weekDays.flatMap(blocks).allSatisfy { ($0["did"] as? [String] ?? []).allSatisfy { $0.count <= 140 } },
              "recap: at most five blocks a day and no line over 140 characters under the bound")
    let month = object(try store.assistantRecap(when: "past 30 days", timezone: zone, now: now))
    try check(days(month).count == MemoryStore.recapMaxDays && month["earlier_days_not_shown"] as? Int == 23, "recap: at most seven days; earlier ones are counted")

    if let out = ProcessInfo.processInfo.environment["DAYDREAM_RECAP_SAMPLE"], !out.isEmpty {
        let dir = URL(fileURLWithPath: out, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var before = [String]()
        for day in [thu, fri] {
            before.append(AssistantView.decorate(try store.openActionResource("macmem://days/\(day).json?timezone=\(zone)", now: now, assistant: true), zone: TimeZone(identifier: zone)!, slim: true))
        }
        try before.joined(separator: "\n").write(to: dir.appendingPathComponent("before-open-day-thu-fri.json"), atomically: true, encoding: .utf8)
        try text.write(to: dir.appendingPathComponent("after-recap-past-2-days.json"), atomically: true, encoding: .utf8)
        try week.write(to: dir.appendingPathComponent("after-recap-past-7-days.json"), atomically: true, encoding: .utf8)
        print("recap sample: before \(before.map(\.utf8.count).reduce(0, +)) bytes (2 day pages), after \(text.utf8.count) bytes")
    }
}
