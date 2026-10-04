// Copyright (c) 2026 The DayDream Authors. Licensed under the MIT License;
// see LICENSE.
//
// The app's side of a damaged history (gold G45, review round 1), compiled with the MacMemApp sources. Launch opens the
// history as it is unless SQLite itself reported it damaged; then it repairs it first, keeping every row it can read
// and the same choices. A history SQLite's whole-file check merely complains about (leaked pages) is never touched. An
// open that fails on damage is repaired and opened again at once. Only when some rows couldn't be read does the app
// say so: one line in the menu that leads to Backup and restore, where the page says the damaged file was kept, with
// the one button that deletes it (and Restore). Choices that couldn't be read back send Start through setup again.
// Also the newer-history words (G61).
//
// Synthetic only: a scratch history folder and preferences in memory. Nothing is launched or recorded.
import SwiftUI
import AppKit
import CSQLite
@testable import MemoryCore
import MemoryUI

@MainActor @main struct HistorySetAsideChecks {
    static var passes = 0, failures = 0
    static func check(_ value: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        if value { passes += 1; print("PASS " + name) } else { failures += 1; print("FAIL " + name + { let d = detail(); return d.isEmpty ? "" : ": " + d }()) }
    }
    static let now = Date()
    static func history(_ home: URL, count: Int) throws {
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        var choices = try store.policy(); choices.blockedApps = ["com.example.private-notes"]; try store.updatePolicy(choices, now: now)
        try store.transaction {
            for n in 0..<count {
                let e = Evidence(id: "m\(n)", at: iso(now.addingTimeInterval(-Double(n) * 60)), kind: "window.changed", app: "Notes", title: "Plan \(n)", synthetic: true)
                let body = try json(e); try store.exec("INSERT INTO records VALUES(?,?,?)", [e.id, body, fingerprint(body)])
            }
        }
    }
    static func poke(_ file: URL, _ offsets: [Int], _ bytes: Data) throws {
        let handle = try FileHandle(forWritingTo: file)
        for offset in offsets { try handle.seek(toOffset: UInt64(offset)); try handle.write(contentsOf: bytes) }
        try handle.close()
    }
    static func rootPage(_ home: URL, _ name: String) -> Int {
        var db: OpaquePointer?; defer { sqlite3_close(db) }
        sqlite3_open(home.appendingPathComponent("memory.sqlite").path, &db)
        var stmt: OpaquePointer?; defer { sqlite3_finalize(stmt) }
        sqlite3_prepare_v2(db, "SELECT rootpage FROM sqlite_master WHERE name='\(name)'", -1, &stmt, nil)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }
    static func moments(_ store: MemoryStore) -> Int { Int((try? store.rows("SELECT count(*) FROM records WHERE id LIKE 'm%'"))?[0][0] ?? "") ?? -1 }
    static func copies(_ home: URL) -> [String] { ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []).filter { $0.hasPrefix("Damaged") } }

    static func main() throws {
        setbuf(stdout, nil)
        // gold/r2-store-perf review round 1: a launch's preparation in its own process (DaydreamLaunchSession runs it off
        // the main thread before the model exists), which the check kills the moment the repair has cleared the damage
        // note. It stays alive after preparing, as the app would until its model opened the history.
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "prepare-child" {
            let home = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
            let outcome = HistoryPreparation.prepare(home: home) { try MemoryStore(home: $0, writable: true, automaticallySyncSearch: false) }
            print("prepared \(outcome.prepared) repair \(outcome.repair != nil)")
            Thread.sleep(forTimeInterval: 60)
            exit(0)
        }
        let base = ProcessInfo.processInfo.environment["TMPDIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let root = base.appendingPathComponent("daydream-history-set-aside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // gold/r2-store-perf: preferences in memory only (cfprefsd ignores CFFIXED_USER_HOME, so a named suite or
        // UserDefaults.standard would write the real ~/Library/Preferences), for launch's and Backup and restore's lines.
        let defaults = SetAsideMemoryDefaults(inMemory: true)!
        BackupSettingsModel.defaults = SetAsideMemoryDefaults(inMemory: true)!
        func done() -> Never {
            try? FileManager.default.removeItem(at: root)
            print("\(passes) history set-aside checks passed, \(failures) failed. Synthetic only.")
            exit(failures == 0 ? 0 : 1)
        }
        func open(_ home: URL, _ said: inout Int) throws -> MemoryStore {
            var count = 0
            let store = try MemoryViewModel.openHistory(home, defaults: defaults, kept: { count += 1 }) {
                try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
            }
            said += count
            return store
        }
        defaults.set(true, forKey: MemoryViewModel.setupCompletedKey)

        // A sound history: launch opens it as it is and says nothing.
        let sound = root.appendingPathComponent("sound")
        try history(sound, count: 200)
        var said = 0
        check(moments(try open(sound, &said)) == 200 && said == 0 && copies(sound).isEmpty, "a sound history: launch opens it as it is and says nothing")

        // Leaked free pages (SQLite's whole-file check lists "never used" pages; every row reads): never touched.
        let leak = root.appendingPathComponent("leaked pages")
        try history(leak, count: 3000)
        try MemoryStore(home: leak, writable: true, automaticallySyncSearch: false).exec("DELETE FROM records WHERE CAST(substr(id,2) AS INTEGER) >= 2000")
        try poke(leak.appendingPathComponent("memory.sqlite"), [32], Data(count: 8))
        let leakBytes = try Data(contentsOf: leak.appendingPathComponent("memory.sqlite"))
        check(StoreIntegrity.health(home: leak) == .damaged, "(leaked free pages: SQLite's whole-file check complains)")
        said = 0
        check(moments(try open(leak, &said)) == 2000 && said == 0 && copies(leak).isEmpty
              && (try? Data(contentsOf: leak.appendingPathComponent("memory.sqlite"))) == leakBytes && defaults.bool(forKey: MemoryViewModel.setupCompletedKey),
              "leaked free pages: launch opens the history in place, byte for byte, with all 2,000 moments, and says nothing")

        // Damage SQLite reported (an index: a lookup failed with its damage code): repaired at launch with every row, and
        // nothing is said (nothing was lost).
        let index = root.appendingPathComponent("index")
        try history(index, count: 2000)
        try poke(index.appendingPathComponent("memory.sqlite"), [(rootPage(index, "sqlite_autoindex_records_1") - 1) * 4096 + 1], Data(repeating: 0xff, count: 7))
        _ = try? MemoryStore(home: index).action("m42", now: now)
        check(StoreIntegrity.damageNoted(index), "(a lookup failed on a damaged index, and SQLite's code was noted)")
        said = 0
        let indexStore = try open(index, &said)
        check(moments(indexStore) == 2000 && (try? indexStore.action("m42", now: now)) != nil && said == 0 && copies(index).isEmpty,
              "damage in an index only: launch repairs it with all 2,000 moments and says nothing")

        // Pages overwritten, the damage noted by a failed read. Another copy of DayDream is open and records into it
        // (it holds the recorder lock): nothing moves.
        let torn = root.appendingPathComponent("torn")
        try history(torn, count: 2000)
        let file = torn.appendingPathComponent("memory.sqlite")
        let pages = (((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int) ?? 0) / 4096
        try poke(file, [pages / 4, pages / 2, 3 * pages / 4].map { $0 * 4096 + 64 }, Data((0..<3000).map { UInt8($0 % 241) }))
        _ = try? MemoryStore(home: torn).timeline(now: now, limit: 1000)
        check(StoreIntegrity.damageNoted(torn), "(a read failed on the damaged pages, and SQLite's code was noted)")
        let tornBytes = try Data(contentsOf: file)
        let held = Darwin.open(torn.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR, 0o600)
        check(held >= 0 && flock(held, LOCK_EX | LOCK_NB) == 0, "(the other copy holds the recorder lock)")
        check(MemoryViewModel.repairDamagedHistory(torn, defaults: defaults) == nil, "another copy of DayDream is open: its history is never repaired from under it")
        check((try? Data(contentsOf: file)) == tornBytes && copies(torn).isEmpty && StoreIntegrity.damageNoted(torn), "…the file stays exactly as it was, and the note stays")
        close(held)
        said = 0
        let tornStore = try open(torn, &said)
        let back = moments(tornStore)
        check(back >= 1900 && said == 1 && copies(torn).count == 1, "launch repairs it: the moments it can read are back, the damaged file is kept, and that is said once",
              "\(back) \(said) \(copies(torn))")
        check(defaults.bool(forKey: MemoryViewModel.setupCompletedKey) && (try? tornStore.policy().blockedApps) == ["com.example.private-notes"],
              "…its choices were kept, so setup stays finished")
        check(StoreIntegrity.health(home: torn) == .sound && (try? tornStore.timeline(now: now, limit: 1000)) != nil, "…and the history DayDream opens is sound and reads")

        // An open that fails on damage (a zeroed header) is repaired and opened again at once: never "Storage unavailable".
        let header = root.appendingPathComponent("header")
        try history(header, count: 300)
        try poke(header.appendingPathComponent("memory.sqlite"), [0], Data(count: 16))
        check(!StoreIntegrity.damageNoted(header), "(nothing noted yet)")
        said = 0
        let headerStore = try? open(header, &said)
        check(headerStore.map(moments) == 300 && said == 1 && defaults.bool(forKey: MemoryViewModel.setupCompletedKey),
              "a history that won't open: repaired and opened in the same launch, with its moments and choices", "\(String(describing: headerStore.map(moments))) \(said)")

        // Nothing could be read back: setup asks for the choices again before anything records.
        let blank = root.appendingPathComponent("blank")
        try history(blank, count: 100)
        let blankFile = blank.appendingPathComponent("memory.sqlite")
        let blankSize = ((try? FileManager.default.attributesOfItem(atPath: blankFile.path))?[.size] as? Int) ?? 0
        try poke(blankFile, [0], Data(count: blankSize))
        said = 0
        check((try? open(blank, &said)) != nil && said == 1, "a history nothing can be read from opens as a new one, and that is said")
        check(!defaults.bool(forKey: MemoryViewModel.setupCompletedKey), "…and Start goes through setup again, so the apps and sites left out are chosen again")

        // gold/r2-store-perf review round 1: launch repairs off the main thread before the model exists
        // (HistoryPreparation). The launch that repaired it can end before the model says the repair (a quit, a logout,
        // a crash), or a second copy can open the history first: the next open says it all the same, once, because the
        // repair writes what to say into the new file itself. The choices here can't be read back (the metadata table's
        // page is overwritten), so an app the person left out would be recorded if nothing sent Start through setup.
        let window = root.appendingPathComponent("repair window")
        try history(window, count: 2000)
        let windowFile = window.appendingPathComponent("memory.sqlite")
        try poke(windowFile, [(rootPage(window, "metadata") - 1) * 4096], Data((0..<4096).map { UInt8(($0 * 7 + 13) % 251) }))
        StoreIntegrity.noteDamage(window)
        let memory = SetAsideMemoryDefaults(inMemory: true)!
        memory.set(true, forKey: MemoryViewModel.setupCompletedKey)
        let child = Process()
        child.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["prepare-child", window.path]
        child.standardOutput = FileHandle.nullDevice
        try child.run()
        var noteCleared = false
        let deadline = Date().addingTimeInterval(120)
        while child.isRunning && Date() < deadline {
            if !StoreIntegrity.damageNoted(window) { noteCleared = true; kill(child.processIdentifier, SIGKILL); break }
            usleep(200)
        }
        if child.isRunning && !noteCleared { kill(child.processIdentifier, SIGKILL) }
        child.waitUntilExit()
        check(noteCleared && child.terminationReason == .uncaughtSignal && copies(window).count == 1,
              "(launch's preparation repaired the history, keeping the damaged file, and was killed the moment it cleared the damage note)",
              "cleared \(noteCleared), reason \(child.terminationReason.rawValue), copies \(copies(window))")
        // The next launch, as DaydreamLaunchSession and the model do it.
        let windowOutcome = HistoryPreparation.needed(home: window)
            ? HistoryPreparation.prepare(home: window) { try MemoryStore(home: $0, writable: true, automaticallySyncSearch: false) } : nil
        said = 0
        let windowStore = try MemoryViewModel.openHistory(window, defaults: memory, repairs: windowOutcome?.prepared != true, kept: { said += 1 }) {
            try MemoryStore(home: window, writable: true, automaticallySyncSearch: false)
        }
        check(!memory.bool(forKey: MemoryViewModel.setupCompletedKey) && said == 1 && (try? windowStore.policy().blockedApps) == [],
              "a repair whose launch ended before the model: the next launch still sends Start through setup (the apps left out couldn't be read back) and says the damaged file was kept",
              "setup finished \(memory.bool(forKey: MemoryViewModel.setupCompletedKey)), said \(said), left out \(String(describing: try? windowStore.policy().blockedApps))")
        memory.set(true, forKey: MemoryViewModel.setupCompletedKey)
        said = 0
        _ = try MemoryViewModel.openHistory(window, defaults: memory, kept: { said += 1 }) { try MemoryStore(home: window, writable: true, automaticallySyncSearch: false) }
        check(said == 0 && memory.bool(forKey: MemoryViewModel.setupCompletedKey), "…said once: the launch after it says nothing and leaves setup as the person finished it")

        // The launch wiring, read from the app's source as recording-model-checks does (a real launch would attach the
        // Keychain typing vault): the repair runs as the store opens and is noted for the menu; its line is the orange line
        // only when nothing else needs saying, and never through `shownIssue` (a stop notice's rule).
        let app = (try? String(contentsOfFile: "Sources/MacMemApp/MacMemApp.swift", encoding: .utf8)) ?? ""
        // gold/r2-store-perf: launch may have repaired it already, off the main thread before the model (HistoryPreparation);
        // then the model says that repair the same way and doesn't look again (store-main-thread-source-checks.py).
        let launch = app.components(separatedBy: "store = try Self.openHistory(MemPaths.home(),repairs:prepared?.prepared != true,kept:{ [backups] in backups.noteHistorySetAside() }) {")
        check(launch.count == 2 && launch[1].prefix(250).contains("try MemoryStore(home:MemPaths.home(),writable:true,automaticallySyncSearch:syncSearch,launchWork:prepared?.prepared == true ? .prepared : .here)")
              && !app.contains("StoreIntegrity.health("), "launch opens the history through the repair (no whole-file check on a usual launch), and notes a kept file for the menu")
        check(app.contains("var shownIssue:String? { operationalIssue }")
              && app.contains("operationalIssue:shownIssue ?? (resumeUnavailable == nil ? historySetAsideIssue : nil)")
              // gold/int: lifecycle shows its derived blocker (shownBlocker) before the set-aside line, which still
              // shows only with no blocker (resumeUnavailable == nil).
              && app.contains("issue:shownIssue ?? shownBlocker ?? (resumeUnavailable == nil ? historySetAsideIssue : nil),"),
              "the damaged-history line is the orange line only when no problem or blocker is shown")

        // One line, leading to Backup and restore; it goes once that page has been seen, or a backup restored.
        check(MenuBarMenu.attentionSection(MenuBarMenu.historySetAsideLine) == "Backup", "the menu's line opens Backup and restore")
        check(DaydreamSettingsPage(section: MenuBarMenu.attentionSection(MenuBarMenu.historySetAsideLine)) == .backup, "…the page with Restore on it")
        check(MenuBarMenu.historySetAsideLine.count <= 45 && !MenuBarMenu.historySetAsideLine.contains("SQLite") && !MenuBarMenu.historySetAsideLine.contains("new one"),
              "the menu's line is short and plain, and never says a new history was started", MenuBarMenu.historySetAsideLine)
        let backups = BackupSettingsModel(home: torn)
        check(backups.damagedCopy && BackupSettingsModel.historySetAsideLine.contains("kept"), "Backup and restore says the damaged file was kept", BackupSettingsModel.historySetAsideLine)
        backups.historySetAsideSeen()
        check(!backups.historySetAside, "no menu line before anything was kept")
        backups.noteHistorySetAside()
        check(backups.historySetAside && BackupSettingsModel(home: torn).historySetAside, "the menu line stays across a relaunch until it has been seen")
        backups.historySetAsideSeen()
        check(!backups.historySetAside && !BackupSettingsModel(home: torn).historySetAside && BackupSettingsModel(home: torn).damagedCopy,
              "seen on Backup and restore: the menu line is gone for good; the page keeps its line while the file is there")
        backups.noteHistorySetAside()
        backups.deleteDamagedCopy()
        check(copies(torn).isEmpty && !backups.damagedCopy && !backups.historySetAside && !BackupSettingsModel(home: torn).damagedCopy
              && (try? MemoryStore(home: torn)).map(moments) == back,
              "\(BackupSettingsModel.deleteDamagedTitle): the damaged file is gone, both lines with it, and the history is untouched")
        BackupSettingsModel.defaults.set(true, forKey: BackupSettingsModel.historySetAsideKey)
        check(!BackupSettingsModel(home: torn).historySetAside, "a line left over after the file was deleted another way is dropped (the menu never points at nothing)")

        // G61: the words the app and AI apps show for a history a newer DayDream saved.
        check(MemoryStore.newerStore.contains("newer DayDream") && MemoryStore.newerStore.contains("Update DayDream"), "a newer history's words say what to do",
              MemoryStore.newerStore)
        done()
    }
}

/// Preferences that live only in this process (gold r2-store-perf review round 1's section): no preferences file is
/// written (a scratch HOME doesn't keep UserDefaults out of ~/Library/Preferences on this macOS).
final class SetAsideMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    init?(inMemory: Bool) { super.init(suiteName: nil) }
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func bool(forKey defaultName: String) -> Bool { (values[defaultName] as? Bool) ?? false }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}
