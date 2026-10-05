// DD-RECIPE: CORE+UI (MemoryCore, HistoryCore, PrivacyPolicy and MemoryUI objects; run-checks.sh "launch-preparation")
// Launch prepares the history off the main thread before the app's model opens it (golden test 5, gold r2-store-perf).
// On a6944d3 the model's init did it on the main thread: the one-time time-index build of a history an earlier DayDream
// saved (2.7 s at two months, 10 s at six on a cold file) and the repair of a history SQLite reported damaged (16 s at
// six months), so the app hung at its first launch. DaydreamLaunchSession now runs HistoryPreparation on a background
// queue first and makes the model when it is done (store-main-thread-source-checks.py checks that wiring).
//   A. A history without the time indexes: `needed` says so at once; `prepare` builds them off the main thread while
//      the main run loop keeps turning (no gap of 100 ms), with the recorder lock held (nothing records meanwhile), and
//      an AI app's reads keep answering; afterwards `needed` says no and the model's writable open is quick.
//      Review round 1: the AI app reads in its own process, as AI apps do (in this process it opened read-only before
//      the preparation's writer existed, so the build failed at once, now and then: the check was flaky), and a reader
//      of this process that opened read-only before the preparation holds a read across the build's first write: the
//      preparation still builds every index (it tried once, and the model's open built the rest on the main thread).
//   F. Review round 1: another process holds a read longer than 1.5 s across the first index's commit (an AI app's
//      whole-table Today read): the preparation waits for it and builds all four; the model's open builds nothing, and
//      never would (`MemoryStore.LaunchWork.prepared`).
//   G. Review round 1: a read held for longer than the preparation's patience: it gives up in about the patience (the
//      app doesn't say "Getting ready…" for as long as the read lasts), says so (`complete` false), the model's open still
//      builds nothing on the main thread, and the next launch's preparation finishes.
//   B (review round 1). The repair's line for the app waits in the new file (`MemoryStore.unsaidRepair`), so no quit
//      between the repair and the model loses it (history-set-aside-checks kills a preparation there).
//   B. A damaged history: `prepare` repairs it (the moments it can read, the same choices, the damaged file kept) before
//      it opens it, holding the recorder lock; the main run loop keeps turning.
//   C. Another copy of DayDream holds the recorder lock: nothing is repaired, opened or built.
//   D. A usual launch (a sound history with its indexes, or none yet) has nothing to prepare.
//   E. The owner build's one-time settle of website typing rows (it reads every record) is part of the preparation,
//      and (review round 1) finishes while another process holds a read across its commit.
// Synthetic histories under $TMPDIR only; no app, Keychain, preferences or permission.
import Foundation
import SQLite3
@testable import MemoryCore

func fail(_ message: String) -> Never { fflush(stdout); FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
var failures = 0
func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
    guard !condition else { return }
    failures += 1; print("FAIL: \(message())"); fflush(stdout)
}
var failuresAtLastPass = 0
func pass(_ message: String) {
    defer { failuresAtLastPass = failures }
    if failures > failuresAtLastPass { print("(no PASS: \(message))"); return }
    print("PASS: \(message)"); fflush(stdout)
}
func wallNow() -> UInt64 { DispatchTime.now().uptimeNanoseconds }
func ms(_ since: UInt64) -> Double { Double(wallNow() - since) / 1e6 }
let SQLITE_TRANSIENT_ = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

final class Raw {
    var db: OpaquePointer?
    init(_ home: URL) {
        guard sqlite3_open(home.appendingPathComponent("memory.sqlite").path, &db) == SQLITE_OK else { fail("raw open") }
        sqlite3_busy_timeout(db, 1500)
    }
    deinit { sqlite3_close(db) }
    @discardableResult func exec(_ sql: String, _ values: [String] = []) -> Int32 {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return sqlite3_errcode(db) }
        defer { sqlite3_finalize(st) }
        for (i, v) in values.enumerated() { sqlite3_bind_text(st, Int32(i + 1), v, -1, SQLITE_TRANSIENT_) }
        var rc = sqlite3_step(st)
        while rc == SQLITE_ROW { rc = sqlite3_step(st) }
        return rc == SQLITE_DONE ? SQLITE_OK : rc
    }
    func count(_ sql: String) -> Int {
        var st: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK else { return -1 }
        defer { sqlite3_finalize(st) }
        return sqlite3_step(st) == SQLITE_ROW ? Int(sqlite3_column_int64(st, 0)) : -1
    }
}

/// Another copy of DayDream's recorder: it holds `capture.lock` while it runs (Coordinator).
func recorderLockFree(_ home: URL) -> Bool {
    let fd = open(home.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return false }
    flock(fd, LOCK_UN)
    return true
}
func indexCount(_ home: URL) -> Int {
    Raw(home).count("SELECT count(*) FROM sqlite_master WHERE type='index' AND name IN (" + MemoryStore.timeIndexNames.map { "'\($0)'" }.joined(separator: ",") + ")")
}

/// A history an earlier DayDream saved: `count` moments with their summaries and none of the time indexes.
func earlyHistory(_ home: URL, count: Int, now: Date) throws {
    _ = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    let raw = Raw(home)
    for name in MemoryStore.timeIndexNames { raw.exec("DROP INDEX IF EXISTS \(name)") }
    let filler = String(repeating: "Worked on a synthetic document in a synthetic app. ", count: 13)
    raw.exec("BEGIN")
    for i in 0..<count {
        let id = "native-early-\(i)", at = iso(now.addingTimeInterval(-Double(i) * 12 - 1))
        let body = "{\"app\":\"Notes\",\"at\":\"\(at)\",\"bundle\":\"com.apple.Notes\",\"id\":\"\(id)\",\"kind\":\"window.changed\",\"privateWindow\":false,\"secure\":false,\"synthetic\":true,\"text\":\"\",\"title\":\"Synthetic document \(i % 97)\",\"url\":\"\"}"
        guard raw.exec("INSERT INTO records VALUES(?,?,?)", [id, body, fingerprint(body)]) == SQLITE_OK,
              raw.exec("INSERT INTO summaries VALUES(?,?,?)", [id, "{\"id\":\"\(id)\",\"generatedAt\":\"\(at)\",\"summary\":\"\(filler)\"}", fingerprint(body)]) == SQLITE_OK else { fail("insert") }
    }
    raw.exec("COMMIT")
}

/// This binary again, in another process (as an AI app's server runs): `mode` and its arguments.
func child(_ arguments: [String]) throws -> (process: Process, output: Pipe) {
    let p = Process(), out = Pipe()
    p.executableURL = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
    p.arguments = arguments
    p.standardOutput = out
    try p.run()
    return (p, out)
}
func waitForFile(_ url: URL, _ seconds: Double = 60) {
    let until = Date().addingTimeInterval(seconds)
    while !FileManager.default.fileExists(atPath: url.path) { guard Date() < until else { fail("a child never started") }; usleep(2_000) }
}
/// The child modes. `ai-reader <home> <started> <stop>`: an AI app's server, one read-only connection kept open (as the
/// MCP server keeps it), reading Today again and again, 10 ms apart, until `stop` appears. `hold <home> <seconds>
/// <ready>`: an AI app's read that holds the file (a read transaction: SQLite's shared lock) for `seconds`.
func childMode() -> Bool {
    let a = CommandLine.arguments
    guard a.count >= 2 else { return false }
    switch a[1] {
    case "ai-reader":
        let home = URL(fileURLWithPath: a[2], isDirectory: true), started = URL(fileURLWithPath: a[3]), stop = URL(fileURLWithPath: a[4])
        let zone = TimeZone.current.identifier
        var reads = 0, failed = 0, first = ""
        do {
            let store = try MemoryStore(home: home)
            while !FileManager.default.fileExists(atPath: stop.path) {
                do { _ = try store.dayLayers(day: try DayScope.key(Date(), timezone: zone), timezone: zone, limit: 100); reads += 1 }
                catch { failed += 1; if first.isEmpty { first = "\(error)" } }
                if reads + failed == 1 { FileManager.default.createFile(atPath: started.path, contents: Data()) }
                usleep(10_000)
            }
        } catch { failed += 1; first = "\(error)"; FileManager.default.createFile(atPath: started.path, contents: Data()) }
        print("\(reads) \(failed) \(first)")
    case "hold":
        let home = URL(fileURLWithPath: a[2], isDirectory: true), seconds = Double(a[3]) ?? 0, ready = URL(fileURLWithPath: a[4])
        var db: OpaquePointer?
        guard sqlite3_open_v2(home.appendingPathComponent("memory.sqlite").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "SELECT count(*) FROM records", nil, nil, nil) == SQLITE_OK else { print("hold failed"); exit(1) }
        FileManager.default.createFile(atPath: ready.path, contents: Data())
        Thread.sleep(forTimeInterval: seconds)
        sqlite3_exec(db, "COMMIT", nil, nil, nil); sqlite3_close(db)
        print("held")
    default: return false
    }
    return true
}

/// `work` on a background queue while a 5 ms timer on the main run loop measures every gap and `alongside` runs on
/// another thread every 10 ms (an AI app's reads): the main thread's longest gap and the work's wall time.
func mainKeepsTurning(during work: @escaping () -> Void, alongside: (() -> Void)? = nil) -> (longest: Double, ticks: Int, workMs: Double) {
    var gaps = [Double](), last = wallNow(), done = false, workMs = 0.0
    let timer = Timer(timeInterval: 0.005, repeats: true) { _ in let n = wallNow(); gaps.append(Double(n - last) / 1e6); last = n }
    RunLoop.main.add(timer, forMode: .common)
    let finished = DispatchSemaphore(value: 0)
    if let alongside {
        DispatchQueue.global(qos: .userInitiated).async {
            while finished.wait(timeout: .now() + 0.01) == .timedOut { alongside() }
        }
    }
    DispatchQueue.global(qos: .userInitiated).async {
        let t = wallNow(); work(); workMs = ms(t)
        finished.signal()
        DispatchQueue.main.async { done = true }
    }
    last = wallNow()
    while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
    timer.invalidate()
    return (gaps.max() ?? 0, gaps.count, workMs)
}

@main struct LaunchPreparationChecks {
    static func main() throws {
        setbuf(stdout, nil)
        if childMode() { exit(0) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 600) { FileHandle.standardError.write(Data("FAIL: launch-preparation-checks watchdog expired after 600s\n".utf8)); exit(2) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("launch-preparation-" + UUID().uuidString, isDirectory: true)
        guard !root.path.hasPrefix("/private/tmp/daydream-"), !root.path.hasPrefix("/tmp/daydream-") else { fail("TMPDIR must be a private scratch folder") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        func open(_ home: URL) throws -> MemoryStore { try MemoryStore(home: home, writable: true, automaticallySyncSearch: false) }

        // MARK: A. A history an earlier DayDream saved: no time indexes.
        let early = root.appendingPathComponent("before-indexes")
        try earlyHistory(early, count: 120_000, now: now)
        expect(indexCount(early) == 0, "(the early history has no time indexes)")
        var t = wallNow()
        let needed = HistoryPreparation.needed(home: early)
        let neededMs = ms(t)
        expect(needed, "a history without the time indexes: launch doesn't see it has work to do before the model")
        expect(neededMs < 50, String(format: "telling whether launch has work took %.0f ms on the main thread", neededMs))
        pass(String(format: "a history without the time indexes: launch sees it has work to do before the model (%.1f ms)", neededMs))

        // The reference: the same open on the main thread, as a6944d3's model did (a copy, so the history stays early).
        let reference = root.appendingPathComponent("reference")
        try FileManager.default.copyItem(at: early, to: reference)
        t = wallNow()
        _ = try open(reference)
        let onMain = ms(t)
        print(String(format: "  (the same open on the main thread, as the model's init did it: %.0f ms)", onMain))
        try? FileManager.default.removeItem(at: reference)

        // An AI app reads Today in its own process, again and again, from before launch until after.
        let aiStarted = root.appendingPathComponent("ai-started"), aiStop = root.appendingPathComponent("ai-stop")
        let ai = try child(["ai-reader", early.path, aiStarted.path, aiStop.path])
        waitForFile(aiStarted)
        // A reader of this process opened before the preparation (read-only: this process has no writer yet, as when Help ›
        // Report a Problem reads the history while DayDream gets ready) holds a read across the preparation's first write.
        let inProcess = try MemoryStore(home: early)
        expect(!inProcess.inProcessReader, "(the reader of this process opened before any writer: read-only)")
        let holding = DispatchSemaphore(value: 0), released = DispatchSemaphore(value: 0)
        var inProcessCount = -1, heldUntil: UInt64 = 0
        DispatchQueue.global(qos: .userInitiated).async {
            inProcessCount = (try? inProcess.readSnapshot { () -> Int in
                let n = Int((try? inProcess.rows("SELECT count(*) FROM records"))?.first?.first ?? "") ?? -1
                holding.signal()
                Thread.sleep(forTimeInterval: 1.0)
                return n
            }) ?? -2
            heldUntil = wallNow()
            released.signal()
        }
        holding.wait()
        var lockHeldDuringOpen = false, opens = 0, outcome: HistoryPreparation.Outcome?
        var prepareStarted: UInt64 = 0
        let run = mainKeepsTurning(during: {
            prepareStarted = wallNow()
            outcome = HistoryPreparation.prepare(home: early) { home in
                opens += 1
                lockHeldDuringOpen = !recorderLockFree(home)
                return try MemoryStore(home: home, writable: true, automaticallySyncSearch: false, launchWork: .preparation)
            }
        })
        released.wait()
        FileManager.default.createFile(atPath: aiStop.path, contents: Data())
        let aiSaid = String(decoding: ai.output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        ai.process.waitUntilExit()
        let aiParts = aiSaid.split(separator: " ", maxSplits: 2).map(String.init)
        let aiReads = Int(aiParts.first ?? "") ?? -1, aiFailed = aiParts.count > 1 ? Int(aiParts[1]) ?? -1 : -1
        print(String(format: "  prepare: %.0f ms off the main thread; main run loop: %d ticks, longest gap %.1f ms; an AI app's Today reads in its own process: %d (%d failed)", run.workMs, run.ticks, run.longest, aiReads, aiFailed))
        expect(outcome == HistoryPreparation.Outcome(repair: nil, prepared: true, complete: true) && opens == 1, "prepare: \(String(describing: outcome)), \(opens) opens")
        expect(indexCount(early) == MemoryStore.timeIndexNames.count, "after prepare the history has \(indexCount(early)) of \(MemoryStore.timeIndexNames.count) time indexes")
        expect(run.longest < 100, String(format: "the main thread stopped for %.0f ms while launch prepared the history", run.longest))
        expect(run.workMs > 100 || onMain > 100, String(format: "(the build took %.0f ms here, %.0f ms on the main thread: too short to show anything)", run.workMs, onMain))
        pass("launch builds the time indexes off the main thread: it keeps turning (every gap under 100 ms)")
        expect(lockHeldDuringOpen, "the recorder lock was free while launch built the indexes (another copy could have recorded meanwhile)")
        expect(recorderLockFree(early), "launch kept the recorder lock after preparing (the app's recorder couldn't take it)")
        pass("…with the recorder lock held throughout (nothing records meanwhile), and let go after")
        expect(aiReads > 0 && aiFailed == 0, "an AI app's Today reads in its own process while the indexes were built: \(aiReads) answered, \(aiFailed) refused \(aiParts.count > 2 ? aiParts[2] : "")")
        pass("…and an AI app's reads meanwhile, in its own process, all answer")
        expect(inProcessCount == 120_000 && heldUntil > prepareStarted, "(the reader of this process read \(inProcessCount) moments, and held its read after the preparation began: \(heldUntil > prepareStarted))")
        expect(outcome?.complete == true && indexCount(early) == MemoryStore.timeIndexNames.count,
               "a read-only reader of this process that opened before the preparation stopped the build: \(indexCount(early)) of \(MemoryStore.timeIndexNames.count) time indexes")
        pass("a read that a reader of this process opened read-only before the preparation still holds doesn't stop the build (it waits and tries again)")
        t = wallNow()
        expect(!HistoryPreparation.needed(home: early), "after prepare launch still sees work to do (it would prepare at every launch)")
        _ = try MemoryStore(home: early, writable: true, automaticallySyncSearch: false, launchWork: .prepared)
        let reopen = ms(t)
        expect(reopen < 50, String(format: "the model's open after prepare took %.0f ms on the main thread", reopen))
        pass(String(format: "afterwards launch has nothing to prepare, and the model's open takes %.1f ms", reopen))

        // MARK: F. Another process holds a read longer than 1.5 s across the first index's commit.
        let heldHome = root.appendingPathComponent("held read")
        try earlyHistory(heldHome, count: 30_000, now: now)
        let heldReady = root.appendingPathComponent("held-ready")
        let holder = try child(["hold", heldHome.path, "3", heldReady.path])
        waitForFile(heldReady)
        t = wallNow()
        let heldOutcome = HistoryPreparation.prepare(home: heldHome) { try MemoryStore(home: $0, writable: true, automaticallySyncSearch: false, launchWork: .preparation) }
        let heldMs = ms(t)
        holder.process.waitUntilExit()
        print(String(format: "  prepare with another process holding a read for 3 s: %.0f ms", heldMs))
        expect(heldMs > 1600, String(format: "(the preparation took %.0f ms: the read it should have waited for wasn't in its way)", heldMs))
        expect(heldOutcome == HistoryPreparation.Outcome(repair: nil, prepared: true, complete: true) && indexCount(heldHome) == MemoryStore.timeIndexNames.count
               && !HistoryPreparation.needed(home: heldHome),
               "another process held a read across the first commit: \(heldOutcome), \(indexCount(heldHome)) of 4 indexes, needed \(HistoryPreparation.needed(home: heldHome))")
        t = wallNow()
        _ = try MemoryStore(home: heldHome, writable: true, automaticallySyncSearch: false, launchWork: .prepared)
        let heldReopen = ms(t)
        expect(heldReopen < 50, String(format: "the model's open after that took %.0f ms on the main thread", heldReopen))
        pass(String(format: "a read another process holds across the first commit (3 s): the preparation waits and builds all four indexes; the model's open then takes %.1f ms", heldReopen))
        // The model's open never builds one, even when one is missing: that waits for the next launch's preparation.
        Raw(heldHome).exec("DROP INDEX records_at")
        _ = try MemoryStore(home: heldHome, writable: true, automaticallySyncSearch: false, launchWork: .prepared)
        expect(indexCount(heldHome) == MemoryStore.timeIndexNames.count - 1 && HistoryPreparation.needed(home: heldHome),
               "the model's open after launch prepared the history built an index on the main thread")
        _ = try open(heldHome)
        expect(indexCount(heldHome) == MemoryStore.timeIndexNames.count, "(any other open still builds a missing index, as before)")
        pass("the model's open after launch prepared the history builds nothing, even with an index missing (the next launch's preparation builds it)")

        // MARK: G. A read held longer than the preparation's patience.
        let stuck = root.appendingPathComponent("stuck read")
        try earlyHistory(stuck, count: 30_000, now: now)
        let stuckReady = root.appendingPathComponent("stuck-ready")
        let stuckHolder = try child(["hold", stuck.path, "6", stuckReady.path])
        waitForFile(stuckReady)
        t = wallNow()
        let stuckOutcome = HistoryPreparation.prepare(home: stuck, patience: 1.5) { try MemoryStore(home: $0, writable: true, automaticallySyncSearch: false, launchWork: .preparation) }
        let stuckMs = ms(t)
        print(String(format: "  prepare (patience 1.5 s) with a read held for 6 s: %.0f ms, %d of 4 indexes", stuckMs, indexCount(stuck)))
        expect(stuckOutcome == HistoryPreparation.Outcome(repair: nil, prepared: true, complete: false) && HistoryPreparation.needed(home: stuck),
               "a read held past the patience: \(stuckOutcome), needed \(HistoryPreparation.needed(home: stuck))")
        expect(stuckMs < 4500, String(format: "the preparation waited %.0f ms for a read held past its patience of 1.5 s", stuckMs))
        let stuckIndexes = indexCount(stuck)
        t = wallNow()
        _ = try MemoryStore(home: stuck, writable: true, automaticallySyncSearch: false, launchWork: .prepared)
        expect(ms(t) < 50 && indexCount(stuck) == stuckIndexes, "the model's open built what the preparation left, on the main thread")
        stuckHolder.process.waitUntilExit()
        let nextOutcome = HistoryPreparation.prepare(home: stuck) { try MemoryStore(home: $0, writable: true, automaticallySyncSearch: false, launchWork: .preparation) }
        expect(nextOutcome.complete && indexCount(stuck) == MemoryStore.timeIndexNames.count && !HistoryPreparation.needed(home: stuck),
               "the next launch's preparation: \(nextOutcome), \(indexCount(stuck)) of 4 indexes")
        pass("a read held past the preparation's patience: it gives up in about the patience, the model's open builds nothing, and the next launch finishes")

        // MARK: B. A damaged history.
        let damaged = root.appendingPathComponent("damaged")
        do {
            let store = try open(damaged)
            var choices = try store.policy(); choices.blockedApps = ["com.example.private-notes"]; try store.updatePolicy(choices, now: now)
            try store.transaction {
                for n in 0..<3000 {
                    let e = Evidence(id: "m\(n)", at: iso(now.addingTimeInterval(-Double(n) * 60)), kind: "window.changed", app: "Notes", title: "Plan \(n)", synthetic: true)
                    let body = try json(e); try store.exec("INSERT INTO records VALUES(?,?,?)", [e.id, body, fingerprint(body)])
                }
            }
        }
        let file = damaged.appendingPathComponent("memory.sqlite")
        let pages = (((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int) ?? 0) / 4096
        let handle = try FileHandle(forWritingTo: file)
        for page in [pages / 4, pages / 2, 3 * pages / 4] { try handle.seek(toOffset: UInt64(page * 4096 + 64)); try handle.write(contentsOf: Data((0..<3000).map { UInt8($0 % 241) })) }
        try handle.close()
        _ = try? MemoryStore(home: damaged).timeline(now: now, limit: 1000)
        expect(StoreIntegrity.damageNoted(damaged), "(a read failed on the damaged pages, and the damage was noted)")
        expect(HistoryPreparation.needed(home: damaged), "a history SQLite reported damaged: launch doesn't see it has work to do before the model")

        // C first: another copy of DayDream holds the recorder lock. Nothing moves.
        let bytes = try Data(contentsOf: file)
        let held = Darwin.open(damaged.appendingPathComponent("capture.lock").path, O_CREAT | O_RDWR, 0o600)
        expect(held >= 0 && flock(held, LOCK_EX | LOCK_NB) == 0, "(the other copy holds the recorder lock)")
        var openedUnderOther = 0
        let other = HistoryPreparation.prepare(home: damaged) { openedUnderOther += 1; return try open($0) }
        expect(other == HistoryPreparation.Outcome(prepared: false) && openedUnderOther == 0, "another copy is open: launch prepared anyway (\(other), \(openedUnderOther) opens)")
        expect((try? Data(contentsOf: file)) == bytes && StoreIntegrity.damageNoted(damaged)
               && ((try? FileManager.default.contentsOfDirectory(atPath: damaged.path)) ?? []).allSatisfy { !$0.hasPrefix("Damaged") },
               "another copy is open: its history changed under it")
        close(held)
        pass("another copy of DayDream holds the recorder lock: launch repairs, opens and builds nothing")

        var sound = false, keptBeforeOpen = false, lockHeldDuringRepairedOpen = false
        var damagedOutcome: HistoryPreparation.Outcome?
        let repairRun = mainKeepsTurning(during: {
            damagedOutcome = HistoryPreparation.prepare(home: damaged) { home in
                // What the open finds: the repair already made, under the same lock.
                sound = StoreIntegrity.health(home: home) == .sound
                keptBeforeOpen = ((try? FileManager.default.contentsOfDirectory(atPath: home.path)) ?? []).contains { $0.hasPrefix("Damaged") }
                lockHeldDuringRepairedOpen = !recorderLockFree(home)
                return try open(home)
            }
        })
        print(String(format: "  repair: %.0f ms off the main thread; longest main-thread gap %.1f ms", repairRun.workMs, repairRun.longest))
        let back = Raw(damaged).count("SELECT count(*) FROM records WHERE id LIKE 'm%'")
        expect(damagedOutcome?.prepared == true && damagedOutcome?.repair?.copy != nil && damagedOutcome?.repair?.keptChoices == true,
               "the damaged history's preparation: \(String(describing: damagedOutcome))")
        expect(back >= 2900 && (try? open(damaged).policy().blockedApps) == ["com.example.private-notes"],
               "the repaired history has \(back) of 3,000 moments and choices \(String(describing: try? open(damaged).policy().blockedApps))")
        expect(sound && keptBeforeOpen && lockHeldDuringRepairedOpen, "the open came before the repair, or without the recorder lock (sound \(sound), kept \(keptBeforeOpen), lock \(lockHeldDuringRepairedOpen))")
        expect(!StoreIntegrity.damageNoted(damaged) && !HistoryPreparation.needed(home: damaged) && recorderLockFree(damaged) && damagedOutcome?.complete == true,
               "after the repair launch still sees work to do, or kept the lock")
        // Review round 1: what the app says about it (the damaged file kept; the choices were kept) waits in the new file,
        // not only in this outcome, so a quit before the model can't lose it; the app's open says it and clears it.
        let repaired = try open(damaged)
        expect(repaired.unsaidRepair() == MemoryStore.UnsaidRepair(keptChoices: true), "the repair's line isn't waiting in the new file: \(String(describing: repaired.unsaidRepair()))")
        repaired.repairSaid()
        expect(repaired.unsaidRepair() == nil, "the repair's line stays after the app said it")
        expect(repairRun.longest < 100, String(format: "the main thread stopped for %.0f ms while launch repaired the history", repairRun.longest))
        pass("a damaged history is repaired off the main thread before anything opens it, under the recorder lock: its moments and choices, the damaged file kept")

        // A history that won't open at all (a zeroed header, nothing noted yet): the preparation's open fails on the damage,
        // notes it, repairs and opens again, as the model's open does.
        let header = root.appendingPathComponent("header")
        do {
            let store = try open(header)
            try store.transaction {
                for n in 0..<300 {
                    let e = Evidence(id: "m\(n)", at: iso(now.addingTimeInterval(-Double(n) * 60)), kind: "window.changed", app: "Notes", title: "Plan \(n)", synthetic: true)
                    let body = try json(e); try store.exec("INSERT INTO records VALUES(?,?,?)", [e.id, body, fingerprint(body)])
                }
            }
        }
        let headerHandle = try FileHandle(forWritingTo: header.appendingPathComponent("memory.sqlite"))
        try headerHandle.seek(toOffset: 0); try headerHandle.write(contentsOf: Data(count: 16)); try headerHandle.close()
        expect(!StoreIntegrity.damageNoted(header) && HistoryPreparation.needed(home: header), "a history that won't open: launch doesn't see it has work to do")
        var headerOpens = 0
        let headerOutcome = HistoryPreparation.prepare(home: header) { headerOpens += 1; return try open($0) }
        expect(headerOutcome.prepared && headerOutcome.repair != nil && headerOpens == 2 && Raw(header).count("SELECT count(*) FROM records WHERE id LIKE 'm%'") == 300
               && !HistoryPreparation.needed(home: header),
               "a history that won't open: \(headerOutcome), \(headerOpens) opens, \(Raw(header).count("SELECT count(*) FROM records WHERE id LIKE 'm%'")) moments")
        pass("a history that won't open is repaired and opened again in the same preparation, with its moments")

        // MARK: D. A usual launch.
        let usual = root.appendingPathComponent("usual")
        // As the app leaves it after a launch (the owner build settles website typing rows once). wal-1005: the app makes
        // its history in the write-ahead log (one in the rollback journal, as 0.1.4 left it, needs one preparation).
        _ = try MemoryStore(home: usual, writable: true, automaticallySyncSearch: false, liveHistory: true).settleWebsiteTypingRows(now: now)
        t = wallNow()
        expect(!HistoryPreparation.needed(home: usual), "a sound history with its indexes: launch prepares it anyway")
        expect(!HistoryPreparation.needed(home: root.appendingPathComponent("none yet")), "no history yet: launch prepares it anyway")
        let usualMs = ms(t)
        expect(usualMs < 50, String(format: "a usual launch took %.0f ms to see it has nothing to prepare", usualMs))
        pass("a usual launch (a sound history with its indexes, or none yet) goes straight to the model")

        // MARK: E. Website typing rows (owner build).
        if MemoryStore.websiteRows != nil {
            // A history an earlier owner build saved before the settle existed.
            Raw(usual).exec("DELETE FROM metadata WHERE id=?", [MemoryStore.websiteSettleID])
            expect(HistoryPreparation.needed(home: usual), "owner build: website typing rows never settled, and launch sees nothing to prepare (the settle would read every record on the main thread)")
            _ = HistoryPreparation.prepare(home: usual) { try open($0) }
            expect(Raw(usual).count("SELECT count(*) FROM metadata WHERE id='\(MemoryStore.websiteSettleID)'") == 1 && !HistoryPreparation.needed(home: usual),
                   "owner build: the preparation didn't settle website typing rows")
            pass("owner build: the one-time settle of website typing rows is part of the preparation")
            // Review round 1: another process holds a read across the settle's commit (3 s): the preparation waits for it
            // (before, the settle gave up after 1.5 s and the model's launch read every record for it on the main thread).
            Raw(usual).exec("DELETE FROM metadata WHERE id=?", [MemoryStore.websiteSettleID])
            let settleReady = root.appendingPathComponent("settle-ready")
            let settleHolder = try child(["hold", usual.path, "3", settleReady.path])
            waitForFile(settleReady)
            t = wallNow()
            let settled = HistoryPreparation.prepare(home: usual) { try MemoryStore(home: $0, writable: true, automaticallySyncSearch: false, launchWork: .preparation) }
            let settleMs = ms(t)
            settleHolder.process.waitUntilExit()
            // wal-1005: `usual` is in WAL (as the app makes it), where a read never holds a commit up: the settle lands
            // beside the read at once. In the rollback journal it waits for the read (> 1.6 s).
            let wal = HistoryJournal.onDisk(usual.appendingPathComponent("memory.sqlite").path) == .wal
            expect((wal || settleMs > 1600) && settled.complete && Raw(usual).count("SELECT count(*) FROM metadata WHERE id='\(MemoryStore.websiteSettleID)'") == 1
                   && !HistoryPreparation.needed(home: usual),
                   String(format: "owner build: a read held across the settle's commit: %@ after %.0f ms, settled %d", "\(settled)", settleMs,
                          Raw(usual).count("SELECT count(*) FROM metadata WHERE id='\(MemoryStore.websiteSettleID)'")))
            pass(String(format: wal ? "owner build: …and a read another process holds across its commit doesn't hold it up in WAL (%.0f ms)"
                                    : "owner build: …and it waits for a read another process holds across its commit (%.0f ms)", settleMs))
        } else {
            expect(!HistoryPreparation.needed(home: usual), "public build: launch prepares for website typing rows it never keeps")
            pass("public build: no website typing rows to settle, nothing to prepare")
        }

        if failures > 0 { fail("\(failures) expectations failed") }
        print("launch-preparation-checks passed")
    }
}
