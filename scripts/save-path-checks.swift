// DD-RECIPE: CAPTURE (plus PreferenceAutosave.swift, PreferenceProblem.swift, WakeResume.swift and LaunchLocation.swift)
//
// gold/save-path: nothing that passes in a moment stops recording or saving for good. On the actual Coordinator,
// NativeCaptureReceipts, CaptureSession, MemoryStore and PreferenceAutosave, with synthetic stores under TMPDIR:
//   G1  One busy native write (another process holds the file) drops that unit only: the next N events save N rows.
//       A proof read that races another connection never pauses recording. Save authority returns while recording.
//   G2  DayDream's own readers (MemoryStore(home:) in the recorder's process) never make the recorder's writes fail:
//       they wait their turn. Every momentary SQLite code (busy, locked, the lock I/O errors) drops the unit only.
//   (a) A unit that wasn't allowed (denied, no store, typing not accepted) is not a failed save: no pause, no retry.
//   G33 One false permission read never stops recording, takes save authority away or says a permission is off; a
//       loss that holds (about a second) still stops it.
//   (b) A preference save that hit a busy file saves by itself once the file is free, without showing a problem; a
//       file that stays busy past the quiet tries (about 10 s) shows the problem, and the save still lands once free.
//   (r1) An action that saves at once (Exclude App, Don't Record <site>, a site added in Settings) during such a busy
//       moment never says it didn't save while the change is being tried again quietly: it waits for the outcome
//       (saved, or the page's problem line once the quiet tries are used up), never "Unsaved changes…".
// No event tap, no permission read (permissions are a closure), no Accessibility, Keychain or network. A child copy of
// this binary (--hold) holds a read lock on the synthetic file, the way an AI app's MCP read can.
import Foundation
import CSQLite
import HistoryCore
@testable import MemoryCore

@main struct SavePathChecks {
    static var checks = 0, failures = 0
    static func check(_ condition: Bool, _ name: String) {
        if condition { checks += 1; print("PASS " + name) }
        else { failures += 1; FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8)); print("FAIL " + name) }
    }
    /// gold r3-store: lets units written later (the history was held a moment) land: runs the main queue until none wait.
    static func settle(_ c: Coordinator, within: TimeInterval = 10) {
        let end = Date().addingTimeInterval(within)
        while c.unitsWaiting > 0 && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        if c.unitsWaiting > 0 { check(false, "G1: units written later still waiting after \(Int(within)) s (\(c.unitsWaiting))") }
    }
    static func count(_ store: MemoryStore) -> Int { Int((try? store.rows("SELECT count(*) FROM records").first?.first) ?? "0") ?? 0 }
    static func snap(_ i: Int) -> AccessibilitySnapshot {
        AccessibilitySnapshot(focusID: "synthetic-focus-\(i)", app: AppInfo(name: "Notes", bundleIdentifier: "com.apple.Notes"),
                              window: WindowInfo(title: "Synthetic note \(i)", url: nil),
                              element: ElementInfo(role: "AXTextArea", subrole: nil, title: nil, value: nil, identifier: nil),
                              secureInput: false, privateBrowsing: false, selectedText: nil, selectedLocation: nil, selectedLength: nil)
    }

    /// Another process holds a read transaction (SQLite's SHARED lock) on `store`'s file for `seconds`.
    static func hold(_ store: MemoryStore, seconds: Double) throws -> Process {
        let child = Process(), out = Pipe()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--hold", store.home.appendingPathComponent("memory.sqlite").path, String(seconds)]
        child.standardOutput = out
        try child.run()
        var buffer = Data()
        while !String(decoding: buffer, as: UTF8.self).contains("held") {
            let more = out.fileHandleForReading.availableData
            if more.isEmpty { break }
            buffer.append(more)
        }
        return child
    }
    static func holdChild(_ path: String, _ seconds: Double) -> Never {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_exec(db, "BEGIN", nil, nil, nil) == SQLITE_OK,
              sqlite3_exec(db, "SELECT count(*) FROM records", nil, nil, nil) == SQLITE_OK else { exit(3) }
        print("held"); fflush(stdout)
        Thread.sleep(forTimeInterval: seconds)
        sqlite3_exec(db, "COMMIT", nil, nil, nil); sqlite3_close(db)
        exit(0)
    }

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let args = CommandLine.arguments
        if args.count == 4, args[1] == "--hold" { holdChild(args[2], Double(args[3]) ?? 2) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("save-path-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try busyUnit(root)
        try proofRace(root)
        try inProcessReaders(root)
        try classification(root)
        try permissionReads(root)
        try await preferenceRetry(root)
        try await exclusionWhileSaving(root)
        try sources()
        if failures > 0 { print("\(failures) FAILED, \(checks) passed"); exit(1) }
        print("PASS all \(checks) save-path checks. No event tap, permission read or Accessibility read was used.")
    }

    // MARK: G1

    static func busyUnit(_ root: URL) throws {
        let store = try MemoryStore(home: root.appendingPathComponent("g1"), writable: true, automaticallySyncSearch: false)
        let c = try Coordinator(store: store, permissions: { true }) {}
        var faults = 0
        c.onStorageFault = { faults += 1 }
        try c.start()
        for i in 1...5 { c.record(kind: .windowChanged, snapshot: snap(i)) }
        check(count(store) == 5, "G1: five window changes save five rows")
        let holder = try hold(store, seconds: 2.5)
        let started = Date()
        c.record(kind: .windowChanged, snapshot: snap(6))
        let waited = Date().timeIntervalSince(started)
        // gold r3-store: the main thread waits a moment at most (it used to wait out the 1.5 s busy timeout and drop
        // the unit); the unit is written a moment later, once the file is free, off the main thread.
        check(waited < 0.2 && count(store) == 5, "G1: another process holds the file: that one unit waits a moment at most on the main thread (\(Int(waited * 1000)) ms) and isn't written yet")
        check(c.session.state == "recording" && faults == 0, "G1: one busy unit keeps recording (no pause, no retry)")
        holder.waitUntilExit()
        settle(c)
        check(count(store) == 6 && faults == 0 && c.session.state == "recording", "G1: once the file is free the held unit is saved (\(count(store) - 5) of 1), recording on")
        // No heartbeat in between: the unit's own wait must not have taken save authority away.
        let n = 20
        for j in 0..<n { c.record(kind: .windowChanged, snapshot: snap(100 + j)) }
        settle(c)
        check(count(store) == 6 + n, "G1: \(n) events after one busy write save \(n) rows (got \(count(store) - 6))")
        check(c.nativeReceipts.active && c.session.state == "recording", "G1: save authority stays while recording")

        // Chrome page rows take the same path (recordPage).
        c.pause("Paused by you")
        let revision = try store.policy().revision
        _ = try store.savePreferences(MemoryPreferences(blockedApps: [], nativeTyping: false, browserPages: true), expectedRevision: revision)
        try c.start()
        let pages = try store.policy().revision
        func page(_ i: Int) -> Bool {
            c.recordPage(ChromePageRead(windowID: "1", tabID: "\(i)", origin: "https://www.example.org", title: "Synthetic page \(i)", siteOnly: false),
                         appName: "Google Chrome", checkedAt: Date(), policyRevision: pages)
        }
        check(page(1), "G1: a Chrome page row saves")
        let pageHolder = try hold(store, seconds: 2.5)
        check(!page(2) && c.session.state == "recording", "G1: a busy Chrome page row is dropped; recording goes on")
        pageHolder.waitUntilExit()
        let before = count(store)
        var saved = 0
        for i in 3...7 where page(i) { saved += 1 }
        check(saved == 5 && count(store) == before + 5, "G1: the Chrome page rows after a busy one save")

        // Whatever took save authority away while the session records, the heartbeat gives it back.
        c.nativeReceipts.invalidate()
        c.reconcileResume()
        let rows = count(store)
        c.record(kind: .windowChanged, snapshot: snap(500))
        check(c.nativeReceipts.active && count(store) == rows + 1, "G1: the heartbeat restores save authority while recording")
        c.pause("Paused by you")
        c.reconcileResume()
        check(!c.nativeReceipts.active, "G1: and never while paused")
    }

    /// The row is saved before its proof is read. A proof read that races another connection's change ("Actions
    /// changed") is read again, and one that still fails leaves no receipt: never a pause for a row already saved.
    static func proofRace(_ root: URL) throws {
        let home = root.appendingPathComponent("race")
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        let c = try Coordinator(store: store, permissions: { true }) {}
        var faults = 0, pausedAt = 0, dropped = 0
        c.onStorageFault = { faults += 1 }
        try c.start()
        // Coordinator.record calls onPause for each unit it drops (this loop never pauses).
        c.onPause = { dropped += 1 }
        let other = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        final class Flag: @unchecked Sendable { let lock = NSLock(); var on = true
            var value: Bool { get { lock.lock(); defer { lock.unlock() }; return on } set { lock.lock(); on = newValue; lock.unlock() } } }
        let running = Flag()
        let t = Thread { while running.value { try? other.revoke(client: "synthetic-client", recipient: "synthetic-recipient"); usleep(200) } }
        t.start()
        let events = 1500
        for i in 1...events {
            c.record(kind: .windowChanged, snapshot: snap(10_000 + i))
            if c.session.state != "recording" { pausedAt = i; break }
        }
        running.value = false
        // gold r3-store: a unit held a moment is written later, off the main thread; let those land.
        settle(c)
        check(pausedAt == 0 && faults == 0, "G1: \(events) events while another connection keeps changing actions never pause recording (paused at \(pausedAt))")
        // The other connection writes every 0.2 ms, so now and then a unit is held a moment and written later; one
        // held past its patience would be dropped (never a pause here); every other unit is saved, its proof read or not.
        check(count(store) == events - dropped && dropped * 50 < events,
              "G1: and every unit not dropped as busy is saved (\(count(store)) of \(events), \(dropped) busy)")
    }

    // MARK: G2

    static func inProcessReaders(_ root: URL) throws {
        let home = root.appendingPathComponent("g2")
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        let c = try Coordinator(store: store, permissions: { true }) {}
        var faults = 0
        c.onStorageFault = { faults += 1 }
        try c.start()
        for i in 1...3 { c.record(kind: .windowChanged, snapshot: snap(i)) }
        // The app's own readers: the day view, search, Settings › Connections, Report a Problem.
        let reader = try MemoryStore(home: home)
        check(reader.inProcessReader, "G2: a reader opened beside the recorder opens as an in-process reader")
        check((try? reader.rows("PRAGMA query_only").first?.first) == "1", "G2: it reads only (query_only)")
        var refused = false
        do { _ = try reader.rows("DELETE FROM metadata WHERE id='policy' RETURNING id") } catch { refused = true }
        check(refused && (try? store.policy()) != nil, "G2: SQLite itself refuses a write through it")
        var denied = false
        do { try reader.exec("DELETE FROM records") } catch MemError.denied { denied = true }
        check(denied && count(store) == 3, "G2: and every write path refuses it too")

        // A read in progress in the app while the recorder writes: the heartbeat, a unit and a pause wait their turn.
        func whileReading(_ seconds: Double, _ body: () throws -> Void) rethrows {
            let held = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                _ = try? reader.readSnapshot { () -> Int in
                    _ = try reader.rows("SELECT count(*) FROM records"); held.signal()
                    Thread.sleep(forTimeInterval: seconds); return 0
                }
                done.signal()
            }
            held.wait()
            try body()
            done.wait()
        }
        var heartbeat: Error?
        whileReading(0.3) { do { try c.session.health(permitted: true) } catch { heartbeat = error } }
        check(heartbeat == nil, "G2: the heartbeat waits for the app's own read instead of failing (\(heartbeat.map { CaptureFault.logName($0) } ?? "saved"))")
        whileReading(0.3) { c.reconcileResume() }
        check(c.session.state == "recording" && faults == 0, "G2: a heartbeat during the app's own read keeps recording")
        let rows = count(store)
        whileReading(0.3) { c.record(kind: .windowChanged, snapshot: snap(50)) }
        // gold r3-store: a unit that can't go in within a moment is written just after the read, off the main thread.
        settle(c)
        check(count(store) == rows + 1 && faults == 0, "G2: a unit written during the app's own read is saved")

        // Any other reader (another process's, a home this process doesn't write) opens read-only, as before.
        let lone = root.appendingPathComponent("g2-lone")
        do { _ = try MemoryStore(home: lone, writable: true, automaticallySyncSearch: false) }
        let plain = try MemoryStore(home: lone)
        check(!plain.inProcessReader && (try? plain.rows("PRAGMA query_only").first?.first) == "0",
              "G2: a reader of a file this process doesn't write opens read-only as before")
        var readOnly = false
        do { _ = try plain.rows("DELETE FROM metadata WHERE id='policy' RETURNING id") } catch { readOnly = true }
        check(readOnly, "G2: and can't write either")
    }

    // MARK: G2 codes and (a)

    static func classification(_ root: URL) throws {
        for code: Int32 in [5, 261, 517, 773, 6, 262, 518, 3850, 2314, 3594, 5130] {
            let error = MemoryStore.failure("write failed", code: code)
            check(CaptureFault.busy(error) && CaptureFault.classify(error, sessionRecording: true) == .dropUnit,
                  "G2: SQLite code \(code) is momentary: the unit is dropped, recording goes on")
            check(CaptureFault.classify(MemError.database("write failed (code \(code))"), sessionRecording: true) == .dropUnit,
                  "G2: code \(code) is momentary even where the store didn't say busy")
        }
        for code: Int32 in [10, 266, 778, 1034, 13, 8, 11, 26, 2058] {
            let error = MemoryStore.failure("write failed", code: code)
            check(!CaptureFault.busy(error) && CaptureFault.classify(error, sessionRecording: true) == .storage,
                  "G2: SQLite code \(code) is a failed save (pause, then the app tries again)")
        }
        check(CaptureFault.diskFull(MemoryStore.failure("write failed", code: 13)), "G2: a full disk still says so")

        // A real SQLITE_IOERR_LOCK: a plain read-only connection in this process, mid-statement, while the recorder
        // writes (what the app's readers did before). It is momentary: the heartbeat keeps recording.
        let home = root.appendingPathComponent("ioerr")
        let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
        let c = try Coordinator(store: store, permissions: { true }) {}
        var faults = 0
        c.onStorageFault = { faults += 1 }
        try c.start()
        var raw: OpaquePointer?, stmt: OpaquePointer?
        guard sqlite3_open_v2(home.appendingPathComponent("memory.sqlite").path, &raw, SQLITE_OPEN_READONLY, nil) == SQLITE_OK,
              sqlite3_prepare_v2(raw, "SELECT body FROM metadata", -1, &stmt, nil) == SQLITE_OK, sqlite3_step(stmt) == SQLITE_ROW else {
            return check(false, "G2: a raw read-only connection reads")
        }
        var failed: Error?
        do { try c.session.health(permitted: true) } catch { failed = error }
        if let failed {
            check(CaptureFault.busy(failed), "G2: a write that meets a same-process read-only read fails as momentary (\(CaptureFault.logName(failed)))")
            c.reconcileResume()
            check(c.session.state == "recording" && faults == 0, "G2: and a heartbeat that meets it keeps recording")
        } else {
            print("NOTE this SQLite let the write through a same-process read-only read; the momentary codes are checked above")
        }
        sqlite3_finalize(stmt); sqlite3_close(raw)
        c.reconcileResume()
        check(c.session.state == "recording", "G2: once the read is done, recording goes on")

        // (a) A unit that wasn't allowed is not a failed save.
        for (error, name) in [(MemError.denied as Error, "denied"), (MemError.missing, "no store"), (TypedTextError.notAccepted, "typing not accepted")] {
            let fault = CaptureFault.classify(error, sessionRecording: true)
            check(fault.dropsUnitOnly && fault != .dropUnit && fault != .storage && fault != .other,
                  "(a): \(name) is a refusal, not a failed save")
            let before = faults
            c.captureFailed(error, recording: true)
            check(c.session.state == "recording" && faults == before && c.session.reason != CaptureFault.retryReason,
                  "(a): \(name) keeps recording: no \"Couldn't save\" pause, no retry")
        }
        for _ in 0..<(CaptureFaultBudget.limit + 1) { c.captureFailed(MemError.denied, recording: true) }
        check(c.session.state == "recording" && faults == 0, "(a): refusals never add up to a pause for a failed save")
        check(CaptureFault.classify(TypedTextError.typingLocked(.locked), sessionRecording: true) == .typingLocked,
              "(a): a locked typing key is still its own case")
    }

    // MARK: G33

    static func permissionReads(_ root: URL) throws {
        // The settling rule on its own.
        var p = SettledPermission()
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        check(!p.read(false, at: t0), "G33: never allowed: a read that says off is the answer at once")
        check(p.read(true, at: t0), "G33: allowed")
        check(p.read(false, at: t0 + 0.1), "G33: one false read is not a loss")
        check(p.read(true, at: t0 + 0.2) && p.read(false, at: t0 + 0.3) && p.read(false, at: t0 + 0.8), "G33: any true read starts it over")
        check(!p.read(false, at: t0 + 1.3), "G33: false reads for a second, three of them, are a loss")
        var q = SettledPermission(); _ = q.read(true, at: t0)
        for i in 0..<10 { _ = q.read(false, at: t0 + Double(i) * 0.01) }
        check(q.allowed, "G33: many false reads within a moment are still not a loss")
        _ = q.read(false, at: t0 + 1.0)
        check(!q.allowed, "G33: a second of them is")

        // On the actual Coordinator: a queue of reads, then the steady value.
        let store = try MemoryStore(home: root.appendingPathComponent("g33"), writable: true, automaticallySyncSearch: false)
        var permission = true, queue: [Bool] = [], reads = 0
        let c = try Coordinator(store: store, permissions: { reads += 1; return queue.isEmpty ? permission : queue.removeFirst() }) {}
        var clock = t0
        c.now = { clock }
        try c.start()
        // One false read at the heartbeat.
        queue = [false]
        c.reconcileResume()
        check(c.session.state == "recording" && c.recordingSettled, "G33: one false read at the heartbeat keeps recording")
        check((try? store.captureStatus()["state"]) == "recording", "G33: and AI apps still read recording")
        var rows = count(store)
        c.record(kind: .windowChanged, snapshot: snap(1))
        check(count(store) == rows + 1, "G33: and the next unit saves")
        // One false read inside a commit (after the intake gate's read said on).
        queue = [true, false]
        rows = count(store)
        c.record(kind: .windowChanged, snapshot: snap(2))
        check(c.session.state == "recording", "G33: one false read inside a commit keeps recording")
        c.record(kind: .windowChanged, snapshot: snap(3))
        check(count(store) >= rows + 1 && c.nativeReceipts.active, "G33: and saving goes on")
        // A false read right after a good heartbeat's own read never takes save authority away.
        queue = [true, false]
        c.reconcileResume()
        queue = []
        rows = count(store)
        c.record(kind: .windowChanged, snapshot: snap(4))
        check(c.nativeReceipts.active && count(store) == rows + 1, "G33: a false read after the heartbeat keeps save authority")
        // Intake still drops a unit read while a permission reads off (no waiting there).
        queue = [false]
        rows = count(store)
        c.record(kind: .windowChanged, snapshot: snap(5))
        check(count(store) == rows && c.session.state == "recording", "G33: a unit read while a permission reads off is dropped at once")
        // A loss that holds stops recording within about a second.
        permission = false
        var beats = 0
        while c.session.state == "recording" && beats < 10 { c.reconcileResume(); beats += 1; clock += 0.5 }
        check(c.session.state == "permission_denied" && beats == 3 && !c.recordingSettled,
              "G33: a permission that stays off stops recording on the third heartbeat, a second later (took \(beats))")
        check(!c.nativeReceipts.active, "G33: and takes save authority away")
        // Start makes one read, or uses the caller's.
        permission = true
        reads = 0
        try c.start(permitted: false)
        check(c.session.state == "permission_denied" && reads == 0 && !c.nativeReceipts.active,
              "G33: a start the caller read as denied never records, whatever a second read would say")
        try c.start()
        check(c.session.state == "recording" && reads == 1 && c.nativeReceipts.active, "G33: a start reads once")
        c.pause("Paused by you")

        // The notice says what the popover says: a denial the session kept while both permissions read on is Off.
        let stale = RecordingStopCause.infer(sessionState: "permission_denied", sessionReason: "Permission was revoked. Resume explicitly after granting it.",
                                             accessibility: true, inputMonitoring: true, blocker: nil, suspended: false)
        check(stale == .other && stale.retryable, "G33: a kept denial with both permissions on is not a permission stop, and a wake start tries again")
        let notice = RecordingNotice.stopped(stale, resumeTitle: "Start Recording")
        check(notice.map { !$0.body.contains("permission") && !$0.body.contains("Accessibility") && !$0.body.contains("Input Monitoring") } ?? false,
              "G33: its notice never says a permission is off")
        check(RecordingStopCause.infer(sessionState: "permission_denied", sessionReason: nil, accessibility: true, inputMonitoring: false, blocker: nil, suspended: false)
              == .permission(accessibility: false, inputMonitoring: true), "G33: a permission that reads off is still named")
        check(RecordingStopCause.infer(sessionState: "permission_denied", sessionReason: nil, accessibility: nil, inputMonitoring: nil, blocker: nil, suspended: false)
              == .permission(accessibility: false, inputMonitoring: false), "G33: a denial with nothing read is still a permission stop")
    }

    // MARK: (b)

    @MainActor static func preferenceRetry(_ root: URL) async throws {
        @MainActor func settle(_ saver: PreferenceAutosave, within limit: Double) async throws -> Double {
            let start = Date()
            while saver.draft != nil && Date().timeIntervalSince(start) < limit { try await Task.sleep(nanoseconds: 100_000_000) }
            return Date().timeIntervalSince(start)
        }
        // The save itself meets a busy file (recording already off, so the stop writes nothing).
        let quiet = try MemoryStore(home: root.appendingPathComponent("prefs-save"), writable: true, automaticallySyncSearch: false)
        var shown = false, quietStops = 0, quietTries = 0
        let saver = try PreferenceAutosave(store: quiet, stopProducer: { quietStops += 1 })
        saver.onChange = { if saver.error != nil { shown = true }; quietTries = max(quietTries, saver.retries) }
        let holder = try hold(quiet, seconds: 3)
        saver.submit(MemoryPreferences(blockedApps: ["com.apple.Notes"], nativeTyping: false))
        let waited = try await settle(saver, within: 12)
        holder.waitUntilExit()
        check(saver.draft == nil && saver.error == nil && (try? quiet.policy().blockedApps) == ["com.apple.Notes"],
              "(b): a save that met a busy file saves by itself once the file is free (after \(String(format: "%.1f", waited)) s)")
        check(!shown, "(b): no problem line while it tries again for a moment")
        // Recording off, so nothing is saved as recording: only the change's own stop (submit) and its first save's run;
        // a try again by itself adds no stop (whose writes would each wait out the busy file on the main thread).
        check(quietTries >= 1 && quietStops == 2, "(r1): the tries again by themselves stop nothing more (\(quietTries) tries, \(quietStops) stops)")

        // As in the app: recording was on, the change stops it (its stop write meets the busy file too), the save lands
        // by itself, and recording starts again (what MemoryViewModel.preferencesChanged does with resumeAfterSave).
        let store = try MemoryStore(home: root.appendingPathComponent("prefs"), writable: true, automaticallySyncSearch: false)
        let c = try Coordinator(store: store, permissions: { true }) {}
        try c.start()
        var stops = 0, problemShown = false, resumed = false
        let app = try PreferenceAutosave(store: store, stopProducer: { stops += 1; c.stopForPreferences(capture: nil) })
        app.onChange = {
            if app.error != nil { problemShown = true }
            if app.draft == nil, app.error == nil, c.session.state != "recording" { try? c.start(); resumed = c.isRunning }
        }
        let appHolder = try hold(store, seconds: 7)
        app.submit(MemoryPreferences(blockedApps: ["com.apple.Notes"], nativeTyping: false))
        check(stops == 1 && !c.isRunning, "(b): a change stops recording before it saves")
        let appWaited = try await settle(app, within: 20)
        appHolder.waitUntilExit()
        check(app.draft == nil && app.error == nil && (try? store.policy().blockedApps) == ["com.apple.Notes"],
              "(b): with recording on, the change saves by itself once the file is free (after \(String(format: "%.1f", appWaited)) s)")
        check(!problemShown, "(b): and shows no problem line meanwhile")
        check(resumed && c.isRunning, "(b): recording starts again with no click")

        // A busy file that stays busy past the quiet tries: the problem shows (never silent), the tries go on, and
        // the save lands by itself once the file is free. Short delays here; the app waits about 10 s.
        let long = try MemoryStore(home: root.appendingPathComponent("prefs-long"), writable: true, automaticallySyncSearch: false)
        var longShown = false
        let longSaver = try PreferenceAutosave(store: long, stopProducer: {})
        longSaver.retryDelays = Array(repeating: 0.05, count: 6); longSaver.retryEvery = 0.1
        longSaver.onChange = { if longSaver.error == .storageUnavailable && longSaver.retrying { longShown = true } }
        let longHolder = try hold(long, seconds: 9)
        longSaver.submit(MemoryPreferences(blockedApps: ["com.apple.Notes"], nativeTyping: false))
        let start = Date()
        while !longShown && Date().timeIntervalSince(start) < 8.5 { try await Task.sleep(nanoseconds: 100_000_000) }
        check(longShown && longSaver.draft != nil && longHolder.isRunning,
              "(b): a busy file that stays busy shows its problem after the quiet tries (after \(String(format: "%.1f", Date().timeIntervalSince(start))) s)")
        let longWaited = try await settle(longSaver, within: 12)
        longHolder.waitUntilExit()
        check(longSaver.draft == nil && longSaver.error == nil && (try? long.policy().blockedApps) == ["com.apple.Notes"],
              "(b): and still saves by itself once the file is free, and the problem goes (after \(String(format: "%.1f", longWaited)) s more)")

        // A save that fails for good still says so at once, with its one button, and is never retried by itself.
        try store.exec("CREATE TRIGGER fail_preference BEFORE UPDATE ON metadata WHEN NEW.id='policy' BEGIN SELECT RAISE(ABORT,'fixture failure'); END")
        app.submit(MemoryPreferences(blockedApps: [], nativeTyping: false)); app.flush()
        check(app.error == .storageUnavailable && app.draft != nil && !app.retrying, "(b): a save that can't pass in a moment shows its problem at once")
        try store.exec("DROP TRIGGER fail_preference")
        app.flush()
        check(app.error == nil && app.draft == nil, "(b): Save again saves it")
    }

    // MARK: Review round 1: an exclusion during a busy moment

    /// What `MemoryViewModel.excludeApp` / `saveSites` throw after their flush (the same expression): nil when nothing.
    @MainActor static func thrownAfterFlush(_ saver: PreferenceAutosave, differsFromSaved: Bool = true) -> String? {
        saver.failed ? (PreferenceProblem.make(error: saver.error, differsFromSaved: differsFromSaved, waiting: saver.draft != nil) ?? .notSaved).text : nil
    }

    @MainActor final class Woke { var after: Double? }
    /// `saver.settled()`, bounded: seconds until it returned, nil if it did not within `limit` (a check never hangs).
    @MainActor static func settled(_ saver: PreferenceAutosave, within limit: Double, while body: () -> Void = {}) async throws -> Double? {
        let woke = Woke(), start = Date()
        Task { @MainActor in await saver.settled(); woke.after = Date().timeIntervalSince(start) }
        try await Task.sleep(nanoseconds: 20_000_000)
        body()
        while woke.after == nil && Date().timeIntervalSince(start) < limit { try await Task.sleep(nanoseconds: 20_000_000) }
        return woke.after
    }

    @MainActor static func exclusionWhileSaving(_ root: URL) async throws {
        // Exclude App's own lines on the real autosave (queuePreferences → submit; flush()) while another process holds
        // the file past the 1.5 s busy timeout, as in the review's ExcludeStale repro.
        let store = try MemoryStore(home: root.appendingPathComponent("exclude-busy"), writable: true, automaticallySyncSearch: false)
        var statusLines: [String] = []
        let saver = try PreferenceAutosave(store: store, stopProducer: {})
        saver.onChange = {   // MemoryViewModel.preferencesChanged's status line, recorded
            statusLines.append(saver.error != nil ? "Not saved. Recording is stopped." : saver.draft != nil ? "Unsaved changes. Recording is stopped." : "Saved preferences.")
        }
        let holder = try hold(store, seconds: 2.5)
        saver.submit(MemoryPreferences(blockedApps: ["com.example.synthetic"], nativeTyping: false))
        saver.flush()
        let thrown = thrownAfterFlush(saver)
        check(saver.saving && !saver.failed && saver.error == nil && saver.draft != nil,
              "(r1): an exclusion that met a busy file is saving, not failed (saving \(saver.saving), error \(String(describing: saver.error)))")
        check(thrown == nil, "(r1): Exclude App / Don't Record / a site added throws nothing while the save is tried again quietly (got \(thrown ?? "nothing"))")
        check(PreferenceProblem.make(error: saver.error, differsFromSaved: true, waiting: saver.draft != nil) == nil,
              "(r1): and the pages show no problem line meanwhile")
        let waited = try await settled(saver, within: 12)
        holder.waitUntilExit()
        check(waited != nil && !saver.saving && !saver.failed && saver.draft == nil && saver.error == nil && (try? store.policy().blockedApps) == ["com.example.synthetic"],
              "(r1): settled() returns once the exclusion saved by itself (after \(waited.map { String(format: "%.1f", $0) } ?? "never") s)")
        check(statusLines.last == "Saved preferences.", "(r1): the last status line says saved (\(statusLines.last ?? "none"))")
        let again = try await settled(saver, within: 1)
        check((again ?? 1) < 0.1, "(r1): settled() returns at once when nothing is being tried again")

        // A file that stays busy past the quiet tries (short delays here): the wait ends when the problem shows, and
        // what the action throws is the page's own problem line, never a status line.
        let long = try MemoryStore(home: root.appendingPathComponent("exclude-long"), writable: true, automaticallySyncSearch: false)
        let longSaver = try PreferenceAutosave(store: long, stopProducer: {})
        longSaver.retryDelays = Array(repeating: 0.05, count: 6); longSaver.retryEvery = 0.1
        let longHolder = try hold(long, seconds: 9)
        longSaver.submit(MemoryPreferences(blockedApps: ["com.example.synthetic"], nativeTyping: false))
        longSaver.flush()
        check(thrownAfterFlush(longSaver) == nil, "(r1): a long busy file: nothing thrown at first")
        let longWaited = try await settled(longSaver, within: 8.5)
        let longThrown = thrownAfterFlush(longSaver)
        check(longWaited != nil && longSaver.failed && longSaver.retrying && longHolder.isRunning && longThrown == PreferenceProblem.notSaved.text,
              "(r1): once the quiet tries are used up the wait ends with the page's problem line (\(longThrown ?? "nothing"))")
        longSaver.reload()
        longHolder.waitUntilExit()

        // A change dropped while it was saving (Use saved choices): the wait ends and nothing claims it saved.
        let dropped = try MemoryStore(home: root.appendingPathComponent("exclude-dropped"), writable: true, automaticallySyncSearch: false)
        let droppedSaver = try PreferenceAutosave(store: dropped, stopProducer: {})
        let droppedHolder = try hold(dropped, seconds: 2.5)
        droppedSaver.submit(MemoryPreferences(blockedApps: ["com.example.synthetic"], nativeTyping: false))
        droppedSaver.flush()
        let droppedWaited = try await settled(droppedSaver, within: 2) { droppedSaver.reload() }
        droppedHolder.waitUntilExit()
        check(droppedWaited != nil && !droppedSaver.saving && droppedSaver.draft == nil && (try? dropped.policy().blockedApps) == [],
              "(r1): a change dropped while saving ends the wait and was not saved")

        // The app's wiring: the exclusion hooks wait for the outcome and every flush-then-throw uses `failed`.
        let app = try String(contentsOfFile: "Sources/MacMemApp/MacMemApp.swift", encoding: .utf8)
        check(!app.contains("?? privacySaveStatus"), "(r1): no page ever shows the status line (privacySaveStatus) as a problem")
        check(app.components(separatedBy: "if preferenceSave?.failed == true {throw MemError.invalid((preferenceProblem ?? .notSaved).text)}").count == 3,
              "(r1): excludeApp and saveSites throw only when the change failed, with the page's problem line")
        check(app.contains("try await self.excludeAppSaved(bundle)") && app.contains("try await self.excludeSiteSaved(site)"),
              "(r1): Exclude App and Don't Record <site> wait for the save's outcome")
        check(app.components(separatedBy: "        await preferenceSave?.settled()\n").count == 5,
              "(r1): both wait for an earlier change and for their own before they say anything")
        check(app.contains("if preferenceSave?.saving == true,!recordingTrial,!functionalTrial {resumeAfterSave=true;refreshCaptureStatus();return}"),
              "(r1): a resume while a change saves by itself starts recording once it lands, with no \"didn't save\" line")
    }

    // MARK: Wiring the checks above can't run (the app model and a started recorder)

    static func sources() throws {
        let capture = try String(contentsOfFile: "Sources/MacMemApp/EventCapture.swift", encoding: .utf8)
        check(capture.contains("guard coordinator.recordingSettled else { return false }"), "G33: the recorder starts on the settled read")
        check(capture.contains("if self?.coordinator.recordingSettled != true { self?.stop(reason: \"Recording stopped\") }"),
              "G33: the heartbeat stops the recorder only for a loss that holds")
        let app = try String(contentsOfFile: "Sources/MacMemApp/MacMemApp.swift", encoding: .utf8)
        check(app.contains("let running = coordinator?.recordingSettled ?? false") && app.contains("if recording != running { recording = running }"), "G33: one false read never flips the app to not recording")
        check(app.contains("try coordinator.start(permitted:false)"), "G33: Start's own denied read is the one the session keeps")
        check(app.contains("guard coordinator.recordingSettled else { refreshCaptureStatus(); return }"), "G33: Start never leaves a session recording with no recorder")
        check(app.contains("guard !permission || coordinator?.permittedSettled() ?? Self.permissionsGranted() else {"), "G33: one false read never cancels a timed pause")
        // gold/int final review (G33): an automatic start that reads a permission off waits and reads again, and one read
        // decides a start (permission-blip-checks runs it on the real model).
        check(app.contains("if starting == .automatic, !permissionLossSettled, let again=automaticAgain { holdForPermission(again); return }")
              && app.contains("try coordinator.start(permitted:permitted)"), "G33: an automatic start holds for a moment's \"not allowed\"; one read decides a start")
        check(app.contains("guard coordinator.recordingSettled else {coordinator.nativeReceipts.invalidate();nativeCommitReceipt=nil;return nil}"),
              "G33: the setup trial's proof read never takes save authority on one false read")
        // gold/int: the resume after a landed save waits for an unlock or a wake (CRITIC-GAP-autosave; lifecycle-model
        // saveLandsWhileLocked runs it on the real model), so the pin names both halves.
        check(app.contains("if resume && !recordingTrial && !functionalTrial && setupStepForStart() == nil {")
              && app.contains("if wake.suspended || !awake {recordingWanted=true;wake.wantsRecording();pauseBehindSuspension()}")
              && app.contains("else {startCapture()}"),
              "(b): the app starts recording again once a save lands (after an unlock or a wake when it lands behind one)")
        let coordinator = try String(contentsOfFile: "Sources/MacMemApp/Coordinator.swift", encoding: .utf8)
        check(!coordinator.contains("catch {nativeReceipts.invalidate();onPause?();captureFailed"), "G1: a failed unit never takes save authority away")
        let readers = ["Sources/MacMemApp/MacMemApp.swift", "Sources/MacMemApp/ConnectionSettingsModel.swift", "Sources/MacMemApp/ReportProblem.swift"]
        for path in readers {
            let text = try String(contentsOfFile: path, encoding: .utf8)
            check(!text.contains("SQLITE_OPEN_READONLY"), "G2: \(path) opens its readers through MemoryStore")
        }
    }
}
