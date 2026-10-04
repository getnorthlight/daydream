import Foundation

/// "DayDream Preview" (`--preview-sample`): a made-up week in its own scratch folder, for clicking through the levels UI
/// without recording. Nothing here starts capture, reads the screen or asks for a permission: it only writes a store.
///
/// The week is `PreviewSampleFixture` (summaries-v3/examples/week.json, a made-up founder "Riley" and app "Tallybird"),
/// with the moment notes the local writer model (prompt7 + validator9) wrote for that same evidence, and one more day,
/// `PreviewThreadsDay` (a multitasking Monday for threads: an investor update with texts, Slack, a meeting, a pull
/// request, a YouTube break and email cut in). Seeding:
/// 1. re-dates the eight sample days onto the last eight days (today gets the multitasking day, yesterday the busiest
///    one; today's rows end 45 minutes before now);
/// 2. ingests every row through the normal store (typed rows through an in-memory key, never the Keychain);
/// 3. commits each moment's recorded model note through the normal core checks (a moment whose rows changed, or a note
///    core refuses, gets a code note that only says what was open);
/// 4. writes blocks, days, weeks and months with the level code's own extractive writer (LevelGrounding.extractive):
///    real outputs of the level code, re-checked by core on commit. No model runs in the preview.
public enum PreviewSample {
    public static let launchArgument = "--preview-sample"
    /// Seeds again even when today's sample is already there (the preview otherwise reuses it, so a relaunch is quick).
    public static let reseedArgument = "--preview-reseed"
    /// Opens setup at launch, to click through it (nothing there saves, asks or records in the preview).
    public static let setupArgument = "--preview-setup"
    /// Bumped when the fixture or the seeding changes, so an older sample is made again.
    static let seedVersion = 7
    /// Which build made the sample: an owner build (typing flags) ingests typed rows an unflagged build refuses, so a
    /// sample made by a check build is never reused by the app.
    #if DAYDREAM_OWNER_TYPING
    static let flavor = "owner"
    #else
    static let flavor = "public"
    #endif
    public static let environmentKey = "DAYDREAM_PREVIEW_SAMPLE"
    /// The one line the preview shows wherever the recording state would be.
    public static let line = "Preview: sample data, not recording"
    /// Written in the root so a folder can be recognised (and refused unless it has it).
    public static let marker = "PREVIEW-SAMPLE-ONLY"
    static let generator = "code/preview-sample"

    /// The preview's own folder: `<temporary directory>/DayDream Preview Sample`. Never Application Support, never the
    /// real history (MemPaths.home() without MAC_MEM_HOME), never /private/tmp/daydream-*.
    public static func root(temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> URL {
        temporaryDirectory.appendingPathComponent("DayDream Preview Sample", isDirectory: true)
    }
    /// Whether `url` is a folder the preview may use: under the temporary directory, and not a real history's place.
    public static func allowed(_ url: URL, temporaryDirectory: URL = FileManager.default.temporaryDirectory) -> Bool {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        let temp = temporaryDirectory.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(temp.hasSuffix("/") ? temp : temp + "/") else { return false }
        let forbidden = ["/Library/Application Support/", "/private/tmp/daydream-", "/tmp/daydream-"]
        return !forbidden.contains { path.contains($0) } && !path.hasSuffix("/Library/Application Support")
    }

    public struct Report: Codable, Equatable, Sendable {
        public var days: [String] = []
        public var ingested = 0
        public var refused = 0
        public var moments = 0
        public var modelNotes = 0
        public var codeNotes = 0
        public var levels: [String: Int] = [:]
        public var memory = ""
        /// The local day the sample was seeded for, and the seed version (reuse needs both to match).
        public var today = ""
        public var version = 0
        public var flavor = ""
        /// Today's rows were fitted into the time since midnight (early in the day), or the week moved back a day.
        public var fittedToday = false
        public var movedBackADay = false
    }

    /// Makes the folder again from nothing and seeds it. Returns the memory folder (MAC_MEM_HOME) and what was written.
    /// `now`: the preview's clock (the checks fix it); `timezone`: the Mac's zone.
    @discardableResult
    public static func prepare(root: URL, now: Date = Date(), timezone: String = TimeZone.current.identifier,
                               temporaryDirectory: URL = FileManager.default.temporaryDirectory, reuse: Bool = false) throws -> (memory: URL, report: Report) {
        guard allowed(root, temporaryDirectory: temporaryDirectory) else { throw MemError.invalid("The preview folder must be in the temporary folder") }
        let fm = FileManager.default
        let todayKey = try DayScope.key(now, timezone: timezone)
        let memoryURL = root.appendingPathComponent("memory", isDirectory: true)
        // The same day's sample, made by this seed version: opened as it is (a relaunch shouldn't wait for a seed).
        if reuse, fm.fileExists(atPath: root.appendingPathComponent(marker).path),
           let data = try? Data(contentsOf: root.appendingPathComponent("seed-report.json")),
           let old = try? JSONDecoder().decode(Report.self, from: data),
           old.today == todayKey, old.version == seedVersion, old.flavor == flavor, !old.movedBackADay, old.memory == memoryURL.path,
           fm.fileExists(atPath: memoryURL.appendingPathComponent("memory.sqlite").path) {
            return (memoryURL, old)
        }
        if fm.fileExists(atPath: root.path) {
            // Only a folder this preview made is replaced.
            guard fm.fileExists(atPath: root.appendingPathComponent(marker).path) else { throw MemError.invalid("Refusing to replace a folder the preview didn't make") }
            try fm.removeItem(at: root)
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try Data("synthetic-only\n".utf8).write(to: root.appendingPathComponent(marker))
        let memory = root.appendingPathComponent("memory", isDirectory: true)
        for name in ["memory", "backups"] {
            try fm.createDirectory(at: root.appendingPathComponent(name, isDirectory: true), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        var report = try seed(home: memory, now: now, timezone: timezone)
        report.memory = memory.path
        report.today = todayKey; report.version = seedVersion; report.flavor = flavor
        try JSONEncoder().encode(report).write(to: root.appendingPathComponent("seed-report.json"))
        return (memory, report)
    }

    struct Fixture: Decodable {
        struct Bullet: Decodable { var text: String; var actions: [String]; var assertion: String }
        struct Note: Decodable { var actions: [String]; var title: String; var bullets: [Bullet]; var generator: String; var generatorVersion: String }
        var timezone: String
        var notes: [Note]
    }

    /// Sample day i (0 = Monday Sep 14 ... 6 = Sunday Sep 20, 7 = the multitasking Monday Sep 21) goes this many days
    /// before today: today is the multitasking day, yesterday the busiest day (Tuesday), then its Monday, then the rest
    /// of the week backwards.
    static let daysAgo = [2, 1, 7, 6, 5, 4, 3, 0]
    static var sampleDays: Int { daysAgo.count }

    /// Seeds `home` (a new, empty history folder). See the type's comment.
    public static func seed(home: URL, now: Date, timezone: String) throws -> Report {
        // Website typing rows name their provider only in the owner Chrome-typing build (WebTypedRow needs both flags; the public binary must not
        // carry the string: release-scan); elsewhere they keep the placeholder and core refuses them as it would anyway.
        #if DAYDREAM_CHROME_TYPING && DAYDREAM_OWNER_TYPING
        let fixtureJSON = PreviewSampleFixture.json.replacingOccurrences(of: "@web-typing-provider@", with: WebTypedRow.provider)
        #else
        let fixtureJSON = PreviewSampleFixture.json
        #endif
        guard let data = fixtureJSON.data(using: .utf8),
              let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weekRows = raw["evidence"] as? [[String: Any]] else { throw MemError.invalid("Preview sample unreadable") }
        var fixture = try JSONDecoder().decode(Fixture.self, from: data)
        // The multitasking day: its rows after the week's, its notes written like the local writer's (made up, checked
        // by core like any note).
        let threadsDay = PreviewThreadsDay.make()
        let rows = weekRows + threadsDay.rows
        fixture.notes += threadsDay.notes.map { n in
            Fixture.Note(actions: n.ids, title: n.title, bullets: n.bullets.map { Fixture.Bullet(text: $0.text, actions: $0.ids, assertion: $0.assertion) },
                         generator: generator, generatorVersion: "threads-day-1")
        }
        guard let sampleZone = TimeZone(identifier: fixture.timezone), let zone = TimeZone(identifier: timezone) else { throw MemError.invalid("Unknown time zone") }
        var sampleCal = Calendar(identifier: .gregorian); sampleCal.timeZone = sampleZone
        var cal = Calendar(identifier: .gregorian); cal.timeZone = zone
        let today = cal.startOfDay(for: now)

        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        // No writer runs here: the recorded notes (an earlier writer version) are shown as written, never rewritten.
        try store.keepNotesAsWritten()
        // As a person who turned typing on would have it (the sample's sends are typed rows). The key lives in this
        // process only: the preview app opens the history without it, so the typed words stay unreadable.
        let first = now.addingTimeInterval(-8 * 86400)
        var consent = try store.policy(); consent.captureText = true; try store.updatePolicy(consent, now: first)
        try store.attachVault(TypedTextVault(keyStore: InMemoryTypedKeyStore()), now: first)
        try store.setUpTypedVault(now: first)
        try store.acceptSafeTyping(now: first)
        var typed = try store.typedTextPolicy()
        typed.retention = .days30
        typed.categories = TypedCategoryChoices(searchAndAI: true, writing: true, code: true, messagesAndEmail: true, otherWebsites: true)
        typed.shareWithSummaries = .localOnly
        _ = try store.updateTypedTextPolicy(typed, confirmed: true, now: first)

        var report = Report()
        var dayKeys = Set<String>()
        // Today's rows end 45 minutes before now, so today's last block is closed (blocks wait 30 minutes) and the day note
        // is written. Early in the day the busiest sample day doesn't fit before that: its rows move earlier as a whole (the
        // gaps kept). Before it fits whole (about 6:45 AM) the week moves back a day: yesterday is the busiest day and
        // today is empty.
        let cutoff = now.addingTimeInterval(-45 * 60)
        let dayStart = today.addingTimeInterval(60)
        func wall(_ at: Date, _ index: Int, _ shift: Int) -> Date? {
            let c = sampleCal.dateComponents([.hour, .minute, .second], from: at)
            guard let targetDay = cal.date(byAdding: .day, value: -(daysAgo[index] + shift), to: today) else { return nil }
            return cal.date(bySettingHour: c.hour ?? 0, minute: c.minute ?? 0, second: c.second ?? 0, of: targetDay)
        }
        func sampleIndex(_ at: Date) -> Int { (sampleCal.component(.day, from: at)) - 14 }
        let todayIndex = daysAgo.firstIndex(of: 0) ?? 1
        let todayTimes = rows.compactMap { ($0["at"] as? String).flatMap(timestamp) }.filter { sampleIndex($0) == todayIndex }.compactMap { wall($0, todayIndex, 0) }
        var shiftDays = 0
        var fit: (from: Date, to: Date, start: Date, scale: Double)? = nil
        if let first = todayTimes.min(), let last = todayTimes.max(), last > cutoff {
            // Moved earlier only, never squeezed: the threads day's minutes are its point ("~55 min" on a PR must
            // stay 55 minutes), so a day that doesn't fit whole before now moves the week back a day instead.
            let span = max(last.timeIntervalSince(first), 1)
            if cutoff.timeIntervalSince(dayStart) < span { shiftDays = 1 }
            else { fit = (first, last, cutoff.addingTimeInterval(-span), 1) }
        }
        report.fittedToday = fit != nil; report.movedBackADay = shiftDays == 1
        var shifted = [(Date, [String: Any])]()
        for var row in rows {
            guard let atText = row["at"] as? String, let at = timestamp(atText) else { continue }
            let index = sampleIndex(at)
            guard (0..<sampleDays).contains(index), var target = wall(at, index, shiftDays) else { continue }
            if index == todayIndex, let fit { target = fit.start.addingTimeInterval(target.timeIntervalSince(fit.from) * fit.scale) }
            if target > cutoff { continue }
            let delta = target.timeIntervalSince(at)
            func move(_ value: Any?) -> Any? {
                guard let text = value as? String, let d = timestamp(text) else { return value }
                return iso(d.addingTimeInterval(delta))
            }
            row["at"] = iso(target)
            if var p = row["captureProvenance"] as? [String: Any] {
                p["checkedAt"] = move(p["checkedAt"])
                if var unit = p["unit"] as? [String: Any] { unit["startedAt"] = move(unit["startedAt"]); p["unit"] = unit }
                row["captureProvenance"] = p
            }
            if var b = row["browserVerification"] as? [String: Any] { b["checkedAt"] = move(b["checkedAt"]); row["browserVerification"] = b }
            shifted.append((target, row))
            dayKeys.insert(try DayScope.key(target, timezone: timezone))
        }
        for (at, row) in shifted.sorted(by: { $0.0 < $1.0 }) {
            let e = try JSONDecoder().decode(Evidence.self, from: JSONSerialization.data(withJSONObject: row))
            if (try? store.ingest(e, now: at.addingTimeInterval(1))) == true { report.ingested += 1 } else { report.refused += 1 }
        }
        report.days = dayKeys.sorted()

        // Moment notes: the recorded model note written for the most of this moment's actions (the sample's moments can
        // group a little differently from the run that wrote the notes). Only the lines whose cited actions are all in
        // this moment are kept; core checks the note again on commit (a send line needs its sealed send, and so on).
        var byAction = [String: [Int]]()
        for (i, n) in fixture.notes.enumerated() { for a in n.actions { byAction[a, default: []].append(i) } }
        var used = Set<Int>()
        for day in report.days {
            for m in try store.dayLayers(day: day, timezone: timezone, limit: 1, now: now).activities where m.status != "ready" {
                report.moments += 1
                guard let request = try? store.prepareNote(kind: "activity", day: day, timezone: timezone, activityID: m.id, now: now) else { continue }
                let ids = Set(request.actions.map(\.id))
                var overlap = [Int: Int]()
                for a in ids { for i in byAction[a] ?? [] { overlap[i, default: 0] += 1 } }
                let ranked = overlap.filter { !used.contains($0.key) }.sorted { ($0.value, -$0.key) > ($1.value, -$1.key) }
                var committed = false
                for (i, shared) in ranked.prefix(3) {
                    let n = fixture.notes[i]
                    // At least half of the note's actions are here, and at least a third of the moment's.
                    guard shared * 2 >= n.actions.count, shared * 3 >= ids.count else { continue }
                    let bullets = n.bullets.filter { !$0.actions.isEmpty && Set($0.actions).isSubset(of: ids) }
                        .map { NoteBullet(text: $0.text, actionIDs: $0.actions, assertion: $0.assertion) }
                    guard !bullets.isEmpty else { continue }
                    // Core refuses a whole note for one line it can't back: try the note, then without the refused kinds.
                    for attempt in [bullets, bullets.filter { $0.assertion != "submitted" }] where !attempt.isEmpty {
                        if (try? store.commitNote(NoteWriterOutput(requestID: request.id, title: n.title, bullets: attempt, generator: n.generator,
                                                                   generatorVersion: n.generatorVersion), now: now)) != nil {
                            committed = true; break
                        }
                    }
                    if committed { used.insert(i); report.modelNotes += 1; break }
                }
                if committed { continue }
                let app = m.apps.first { !$0.isEmpty && !$0.contains(".") } ?? "an app"
                let subject = m.subject.trimmingCharacters(in: .whitespacesAndNewlines)
                let text = subject.isEmpty ? "Had \(app) open." : "Had \(subject) open in \(app)."
                if (try? store.commitNote(NoteWriterOutput(requestID: request.id, title: subject.isEmpty ? app : subject,
                                                           bullets: [NoteBullet(text: text, actionIDs: request.actions.map(\.id), assertion: "observed")],
                                                           generator: generator, generatorVersion: "1"), now: now)) != nil {
                    report.codeNotes += 1
                }
            }
        }

        // Levels: blocks, then days, weeks and months, each from the level below (levelWork orders them).
        var guardCount = 0
        while guardCount < 400, let request = try store.levelWork(timezone: timezone, now: now, backfillDays: 8, limit: 1).first {
            guardCount += 1
            let (title, lines) = LevelGrounding.extractive(request)
            let note = try store.commitLevel(request, title: title, lines: lines, generator: LevelWriterVersion.extractive, now: now)
            report.levels[note.level.rawValue, default: 0] += 1
        }
        return report
    }

    /// An MCP entry an AI app can use to read the preview history (`mac-mem mcp` over the preview folder, with a
    /// read grant made for it). Written next to the history as `mcp-server.json`; nothing is written into any AI app.
    @discardableResult
    public static func writeMCPEntry(root: URL, memory: URL, command: URL) throws -> URL {
        let store = try MemoryStore(home: memory, writable: true, automaticallySyncSearch: false)
        let client = "preview", recipient = "daydream-preview"
        let key = try store.grant(client: client, recipient: recipient, scopes: ["context", "search", "detail"])
        let entry: [String: Any] = ["mcpServers": ["daydream-preview": [
            "command": command.path,
            "args": ["--home", memory.path, "--client", client, "--recipient", recipient, "mcp"],
            "env": ["MAC_MEM_CAPABILITY": key]]]]
        let url = root.appendingPathComponent("mcp-server.json")
        try JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url
    }
}
