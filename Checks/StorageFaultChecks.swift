import Foundation
import CSQLite
import MemoryCore
import HistoryCore

/// A save that fails for a moment never stops recording for good (the lock-resume fix). Synthetic store under the
/// checks' temporary folder; a second raw SQLite connection holds the file the way another DayDream connection or
/// a backup can. No capture, no permissions.
func runStorageFaultChecks(home: URL, now: Date) throws {
    let store = try MemoryStore(home:home,writable:true)
    let session = try CaptureSession(store:store)
    try session.start(permitted:true,now:now)

    // Another connection holds the write lock past the busy timeout: the error says busy, with SQLite's code.
    var other: OpaquePointer?
    guard sqlite3_open_v2(home.appendingPathComponent("memory.sqlite").path, &other, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let other else {
        throw MemError.invalid("FAILED: second connection did not open")
    }
    defer { sqlite3_close(other) }
    try check(sqlite3_exec(other,"BEGIN IMMEDIATE",nil,nil,nil) == SQLITE_OK, "a second connection holds the write lock")
    var held: Error?
    do { try store.setCaptureState("recording",reason:"held",now:now) } catch { held = error }
    try check(held.map { CaptureFault.busy($0) } ?? false, "a write while another connection holds the file fails as busy, not as broken storage")
    try check((held as? MemError)?.sqliteCode.map { $0 & 0xff } == SQLITE_BUSY, "the busy error keeps SQLite's code")
    for code: Int32 in [5, 261, 517, 773, 6, 262, 518, 3850, 2314, 3594, 5130] {
        try check(MemoryStore.momentary(code), "SQLite code \(code) is momentary")
    }
    for code: Int32 in [10, 266, 778, 1034, 13, 8, 11, 26, 2058] {
        try check(!MemoryStore.momentary(code), "SQLite code \(code) is not momentary")
    }
    try check(held.map { CaptureFault.classify($0,sessionRecording:true) } == .dropUnit, "busy drops the unit only")
    try check(!(held.map { CaptureFault.logName($0) } ?? "").contains("held"), "the log name never carries the reason text")
    // The heartbeat fails the same way, and leaves the session recording.
    held = nil
    do { try session.health(permitted:true) } catch { held = error }
    try check(held.map { CaptureFault.busy($0) } ?? false && session.state == "recording", "a busy heartbeat leaves the session recording")
    try check(sqlite3_exec(other,"COMMIT",nil,nil,nil) == SQLITE_OK, "the second connection lets go")
    try session.health(permitted:true)
    try check(try store.captureStatus()["state"] == "recording", "the next heartbeat saves once the file is free")

    // What a failed write means.
    let cases: [(Error, CaptureFault, String)] = [
        (MemError.busy("write failed (code 5)"), .dropUnit, "busy"),
        (MemError.busy("write failed (code 6)"), .dropUnit, "locked"),
        (MemError.invalid("Capture is not recording"), .dropUnit, "a late heartbeat"),
        (MemError.invalid("Capture policy changed before commit"), .dropUnit, "a policy saved mid-commit"),
        (MemError.invalid("Recording session changed before commit"), .dropUnit, "a session change mid-commit"),
        (TypedTextError.typingLocked(.locked), .typingLocked, "a locked typing key"),
        (MemError.database("write failed (code 13)"), .storage, "disk full"),
        (MemError.database("write failed (code 10)"), .storage, "I/O error"),
        (MemError.database("write failed (code 8)"), .storage, "read-only"),
        (MemError.invalid("Something unexpected"), .other, "an unknown refusal"),
        // gold/save-path: a unit that wasn't allowed is a refusal (no "Couldn't save", no retry), and every momentary
        // SQLite code drops the unit only, however the store named it.
        (MemError.denied, .refused, "denied"),
        (MemError.missing, .refused, "no store"),
        (TypedTextError.notAccepted, .refused, "typing not accepted"),
        (MemError.busy("write failed (code 3850)"), .dropUnit, "a lock that couldn't be taken"),
        (MemError.database("write failed (code 3850)"), .dropUnit, "SQLITE_IOERR_LOCK named as a database error"),
        (MemError.database("write failed (code 517)"), .dropUnit, "SQLITE_BUSY_SNAPSHOT"),
        (MemError.database("write failed (code 262)"), .dropUnit, "SQLITE_LOCKED_SHAREDCACHE"),
        (MemError.database("write failed (code 1034)"), .storage, "an fsync error"),
        (CocoaError(.fileWriteUnknown), .other, "a non-store error"),
    ]
    for (error, want, name) in cases {
        try check(CaptureFault.classify(error,sessionRecording:true) == want, "classify \(name)")
    }
    try check(CaptureFault.classify(MemError.busy("x"),sessionRecording:true).dropsUnitOnly
              && CaptureFault.classify(TypedTextError.typingLocked(.locked),sessionRecording:true).dropsUnitOnly
              && !CaptureFault.classify(MemError.database("write failed (code 10)"),sessionRecording:true).dropsUnitOnly, "only momentary faults keep recording")
    try check(CaptureFault.diskFull(MemError.database("write failed (code 13)")) && !CaptureFault.diskFull(MemError.database("write failed (code 10)"))
              && !CaptureFault.diskFull(MemError.database("write failed (code 266)")) && !CaptureFault.diskFull(MemError.busy("write failed (code 5)")),
              "disk full is SQLITE_FULL only (the primary code of an extended one)")
    try check(CaptureFault.staleHeartbeat(MemError.invalid("Capture is not recording"),sessionRecording:true)
              && !CaptureFault.staleHeartbeat(MemError.invalid("Capture is not recording"),sessionRecording:false), "a late heartbeat is noticed only while the session records")
    try check(MemError.database("statement failed").sqliteCode == nil && MemError.invalid("(code 5)").sqliteCode == nil, "no code where the store wrote none")

    // Five dropped units within a minute pause recording once; fewer, or spread out, never do.
    var budget = CaptureFaultBudget()
    var paused = 0
    for i in 0..<4 { if budget.dropped(at:now.addingTimeInterval(Double(i))) { paused += 1 } }
    try check(paused == 0 && budget.count == 4, "four dropped units keep recording")
    if budget.dropped(at:now.addingTimeInterval(4)) { paused += 1 }
    try check(paused == 1 && budget.count == 0, "the fifth within a minute pauses once, and the count starts again")
    budget.reset()
    for i in 0..<10 { if budget.dropped(at:now.addingTimeInterval(Double(i) * 20)) { paused += 1 } }
    try check(paused == 1, "one dropped unit every 20 seconds never pauses")

    // The heartbeat's time is taken once the session is free: a heartbeat that waited for a long commit never writes
    // a checked_at that is already stale.
    let slowStore = try MemoryStore(home:home.appendingPathComponent("slow"),writable:true)
    let wait: TimeInterval = 2.5
    let persisting = NSLock()
    var persistCalls = 0
    var committedAt = Date.distantFuture
    // The commit only waits: it saves nothing (this check is about the heartbeat's time). It notes when it ends, still
    // holding the session.
    let committing = DispatchSemaphore(value:0)
    let slow = try CaptureSession(store:slowStore,persist:{ _,_ in
        committing.signal()
        Thread.sleep(forTimeInterval:wait)
        persisting.lock(); persistCalls += 1; committedAt = Date(); persisting.unlock()
        return false
    })
    try slow.start(permitted:true)
    let e = Evidence(id:"slow-commit",at:iso(Date()),kind:"app.focus",app:"TextEdit",bundle:"com.apple.TextEdit",title:"Fabricated notes",synthetic:true)
    let group = DispatchGroup()
    group.enter()
    DispatchQueue.global().async { _ = try? slow.record(e,focusedFieldKnown:true,permitted:true); group.leave() }
    committing.wait() // the commit holds the session now
    try slow.health(permitted:true)
    group.wait()
    try check(persistCalls == 1, "the slow commit ran while the heartbeat waited")
    let checked = try slowStore.captureStatus()["checked_at"].flatMap(timestamp)
    // iso() keeps whole seconds; allow one.
    try check(checked.map { $0 >= committedAt.addingTimeInterval(-1.0) } ?? false, "a heartbeat that waited for a commit is dated after it")
    try check(try slowStore.captureStatus(now:committedAt.addingTimeInterval(3))["state"] == "recording", "and still reads live seconds after the commit")
    print("Storage fault checks use a synthetic store and a second SQLite connection. No capture was started.")
}
