// DD-RECIPE: CAPTURE
//
// A failed capture write never stops recording for good (the lock-resume fix), on the actual Coordinator and
// EventCapture with a synthetic store under TMPDIR and permissions faked on. No event tap, no Accessibility read, no
// permission request: EventCapture is only created and stopped (never started). Compiled like
// production-event-capture-checks.swift: the capture file list from scripts/daydream-core-source-checks.py plus the
// MemoryCore, HistoryCore and PrivacyPolicy objects.
import Foundation
import CSQLite
import HistoryCore
import MemoryCore

@main struct RecordingFaultChecks {
    static var checks = 0
    static func check(_ condition: Bool, _ name: String) {
        guard condition else { FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8)); exit(1) }
        checks += 1; print("PASS " + name)
    }

    final class Probe {
        var faults = 0, healthy = 0, states = 0
    }

    static func coordinator(_ root: URL, _ name: String) throws -> (MemoryStore, Coordinator, Probe) {
        let store = try MemoryStore(home: root.appendingPathComponent(name), writable: true, automaticallySyncSearch: false)
        let coordinator = try Coordinator(store: store, permissions: { true }) {}
        let probe = Probe()
        coordinator.onStorageFault = { probe.faults += 1 }
        coordinator.onHealthy = { probe.healthy += 1 }
        coordinator.onStateChanged = { probe.states += 1 }
        return (store, coordinator, probe)
    }

    static func main() throws {
        setbuf(stdout, nil)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("recording-fault-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let io = MemError.database("write failed (code 10)")
        let full = MemError.database("write failed (code 13)")
        let busy = MemError.busy("write failed (code 5)")

        // A write that fails for good while recording: recording pauses with the retry reason (never an "error" state
        // that only quitting cleared), and the app is told once so it starts recording again by itself.
        var (store, c, probe) = try coordinator(root, "storage")
        try c.start()
        check(c.isRunning, "the synthetic session records")
        c.captureFailed(io)
        check(!c.isRunning && c.session.state == "paused" && c.session.reason == CaptureFault.retryReason, "a failed save pauses recording for a retry")
        check(try store.captureStatus()["reason"] == CaptureFault.retryReason, "the retry pause is saved")
        check(probe.faults == 1 && !c.storageFull, "the app hears of the failed save once")
        // The recorder's timer runs once more before it stops itself, and that heartbeat saves (the file is fine now).
        // Recording is still paused, so it is no recovery: the app's retry, a fresh Start, must still run.
        c.reconcileResume()
        check(probe.healthy == 0 && !c.isRunning && c.session.reason == CaptureFault.retryReason,
              "a good heartbeat while paused for a retry does not say saving works again")
        try c.start()
        c.captureFailed(full)
        check(c.session.reason == CaptureFault.fullReason && c.storageFull && probe.faults == 2, "a full disk says so")
        // The session paused itself inside the failing write (CaptureSession.record): the write was still made while
        // recording, so the app is told.
        try c.start()
        try c.session.pause(CaptureFault.retryReason)
        c.captureFailed(io, recording: true)
        check(probe.faults == 3 && !c.storageFull, "a write that failed while recording is retried even after the session paused itself")
        // A write that fails after the person paused changes nothing: nothing starts recording again.
        c.pause("Paused by you")
        c.captureFailed(io)
        check(probe.faults == 3 && c.session.reason == "Paused by you", "a late write after the person's pause is not retried")

        // Momentary faults drop the unit only. Five within a minute pause once.
        var clock = Date(timeIntervalSince1970: 1_790_000_000)
        c.now = { clock }
        try c.start()
        for _ in 0..<4 { c.captureFailed(busy); clock += 3 }
        check(c.isRunning && probe.faults == 3, "four busy writes in a minute keep recording")
        c.captureFailed(busy)
        check(!c.isRunning && c.session.reason == CaptureFault.retryReason && probe.faults == 4, "the fifth pauses once, for a retry")
        c.reconcileResume()
        check(probe.healthy == 0, "a good heartbeat after the fifth, while paused, does not say saving works again")
        try c.start()
        for _ in 0..<10 { c.captureFailed(busy); clock += 20 }
        check(c.isRunning && probe.faults == 4, "a busy write every 20 seconds never pauses")
        clock += 120
        c.captureFailed(TypedTextError.typingLocked(.locked))
        check(c.isRunning && probe.faults == 4, "a locked typing key drops the unit; recording goes on")
        c.captureFailed(MemError.invalid("Capture policy changed before commit"))
        check(c.isRunning && probe.faults == 4, "a policy saved mid-commit drops the unit; recording goes on")

        // A unit refused because the heartbeat ran late: a heartbeat is written at once, so the next unit is taken.
        try c.session.health(permitted: true, now: Date().addingTimeInterval(-10))
        check(try store.captureStatus()["state"] == "unavailable", "a late heartbeat reads as not live")
        c.captureFailed(MemError.invalid("Capture is not recording"))
        check(c.isRunning && probe.faults == 4, "the refusal keeps recording")
        check(try store.captureStatus()["state"] == "recording", "and writes a fresh heartbeat")
        let before = probe.healthy
        c.reconcileResume()
        c.reconcileResume()
        check(probe.healthy == before + 1, "the next good heartbeat after a fault says saving works again, once")

        // The heartbeat while another connection holds the file: it keeps recording for about 4.5 s held, then pauses.
        // gold r3-store: a heartbeat waits a moment at most on the main thread (it used to wait the 1.5 s busy timeout),
        // and one held up that way counts as a failed heartbeat once per 1.5 s held: two such keep recording, the third
        // pauses, at the same time held as before (0, 1.5, 3 s held keep recording; 4.5 s pauses).
        (store, c, probe) = try coordinator(root, "heartbeat")
        var heldClock = Date()
        c.now = { heldClock }
        try c.start()
        var other: OpaquePointer?
        guard sqlite3_open_v2(store.home.appendingPathComponent("memory.sqlite").path, &other, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let other else {
            return check(false, "a second connection opens")
        }
        defer { sqlite3_close(other) }
        check(sqlite3_exec(other, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK, "a second connection holds the write lock")
        let heldStarted = Date()
        c.reconcileResume()
        heldClock += 1.5; c.reconcileResume()
        heldClock += 1.5; c.reconcileResume()
        check(Date().timeIntervalSince(heldStarted) < 0.5, "three held heartbeats wait a moment each at most (\(Int(Date().timeIntervalSince(heldStarted) * 1000)) ms in all)")
        check(c.isRunning && probe.faults == 0, "two busy heartbeats (3 s held) keep recording")
        heldClock += 1.5; c.reconcileResume()
        // The pause itself can't be saved while the file is held (the session keeps it in memory); the app shows its
        // retry line whatever the session could write.
        check(!c.isRunning && c.session.state != "recording" && probe.faults == 1, "the third (4.5 s held) pauses for a retry")
        check(sqlite3_exec(other, "COMMIT", nil, nil, nil) == SQLITE_OK, "the second connection lets go")
        try c.start()
        c.reconcileResume()
        check(c.isRunning && probe.healthy == 1, "once the file is free, recording starts and the heartbeat says saving works again")
        c.pause("Paused by you")

        // A recorder that stops tells the app once, so it is never taken for live again (a later lock would otherwise
        // write "Resumes after unlock" over why it stopped). Never started here: no event tap.
        let capture = EventCapture(coordinator: c)
        var stops = 0
        capture.onStopped = { stops += 1 }
        capture.stop(reason: "Recording stopped")
        capture.stop(reason: "Recording stopped")
        check(stops == 1 && capture.isStopped, "a stopped recorder says so once")
        check(c.session.reason == "Paused by you", "stopping a recorder keeps the pause's reason")

        // The heartbeat keeps running while a menu is open, and App Nap can't hold it back.
        let source = try String(contentsOfFile: "Sources/MacMemApp/EventCapture.swift", encoding: .utf8)
        check(source.contains("RunLoop.main.add(timer, forMode: .common)") && !source.contains("controlTimer = Timer.scheduledTimer"),
              "the heartbeat runs in the common run-loop modes")
        check(source.contains("beginActivity(options: [.userInitiatedAllowingIdleSystemSleep]") && source.contains("endActivity(activity)"),
              "recording holds an App Nap opt-out and lets it go on stop")
        check(!source.contains("captureFailed()"), "every failed capture write reports its error")
        print("PASS all \(checks) recording-fault checks. No event tap, permission or Accessibility read was used.")
    }
}
