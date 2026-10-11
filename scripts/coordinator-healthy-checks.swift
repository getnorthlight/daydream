// DD-RECIPE: CAPTURE
//
// test-p2-int: the Coordinator's own "saving works again" rule, with no app around it. Coordinator.applyBeat says
// `onHealthy` only for a good heartbeat WHILE RECORDING after a fault (Coordinator.swift: `if faulted && session.state
// == "recording"`). The app's handler checks `recording` again (MacMemApp.swift: `guard let self, self.recording`), so a
// check through the app can't tell when the Coordinator's own guard is gone: the app's guard hides it. Here the
// Coordinator's callback is a counter, so only the Coordinator's guard stands between a paused session and a false
// "Saving works again." (which ends the app's retry, StorageRetry, while nothing records).
//
// The actual Coordinator (the runner's headless copy) over a synthetic store under TMPDIR, permissions faked on. No
// event tap, no Accessibility read, no permission request, no app. Compiled like recording-fault-checks.swift.
import Foundation
import CSQLite
import HistoryCore
import MemoryCore

var ddFailures = 0
func ddFail(_ label: String) { ddFailures += 1; print("FAIL " + label) }

@main struct CoordinatorHealthyChecks {
    static var passes = 0
    static func check(_ condition: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        guard condition else { ddFail(name + { let d = detail(); return d.isEmpty ? "" : " (" + d + ")" }()); return }
        passes += 1; print("PASS " + name)
    }

    final class Probe { var healthy = 0, faults = 0 }

    static func coordinator(_ root: URL, _ name: String) throws -> (MemoryStore, Coordinator, Probe) {
        let store = try MemoryStore(home: root.appendingPathComponent(name), writable: true, automaticallySyncSearch: false)
        let coordinator = try Coordinator(store: store, permissions: { true }) {}
        let probe = Probe()
        coordinator.onHealthy = { probe.healthy += 1 }
        coordinator.onStorageFault = { probe.faults += 1 }
        return (store, coordinator, probe)
    }

    static func main() throws {
        setvbuf(stdout, nil, _IOLBF, 0)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("coordinator-healthy-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let io = MemError.database("write failed (code 10)")
        let busy = MemError.busy("write failed (code 5)")

        // 1. The control: a momentary fault while recording, then a good heartbeat while still recording: once.
        var (_, c, probe) = try coordinator(root, "control")
        try c.start()
        check(c.isRunning, "control: the synthetic session records")
        c.captureFailed(busy)
        check(c.isRunning && probe.faults == 0, "control: a busy write drops the unit and recording goes on")
        c.reconcileResume()
        check(probe.healthy == 1, "control: the next good heartbeat while recording says saving works again", "healthy \(probe.healthy)")
        c.reconcileResume()
        check(probe.healthy == 1, "control: and only once (the fault is cleared)", "healthy \(probe.healthy)")

        // 2. A failed save pauses for a retry; heartbeats while paused (the recorder's timer runs once more before it
        // stops) are good, but nothing records: never "saving works again".
        (_, c, probe) = try coordinator(root, "retry-pause")
        try c.start()
        c.captureFailed(io)
        check(!c.isRunning && c.session.reason == CaptureFault.retryReason && probe.faults == 1, "retry pause: a failed save pauses for a retry")
        for _ in 0..<3 { c.reconcileResume() }
        check(probe.healthy == 0, "retry pause: three good heartbeats while paused never say saving works again", "healthy \(probe.healthy)")
        // The app's retry (a fresh Start) records again: the first good heartbeat then says so, once.
        try c.start()
        c.reconcileResume(); c.reconcileResume()
        check(c.isRunning && probe.healthy == 1, "retry pause: after Start, the first good heartbeat while recording says it, once", "healthy \(probe.healthy)")

        // 3. A momentary fault while recording, then the person pauses before any good heartbeat: heartbeats while
        // paused say nothing; the fault is still owed and is said once recording starts again.
        (_, c, probe) = try coordinator(root, "person-pause")
        try c.start()
        c.captureFailed(busy)
        c.pause("Paused by you")
        check(!c.isRunning && c.session.reason == "Paused by you", "person pause: paused by the person after a momentary fault")
        for _ in 0..<3 { c.reconcileResume() }
        check(probe.healthy == 0, "person pause: good heartbeats while the person paused never say saving works again", "healthy \(probe.healthy)")
        try c.start()
        c.reconcileResume()
        check(probe.healthy == 1, "person pause: once recording again, the next good heartbeat says it (once)", "healthy \(probe.healthy)")

        // 4. Stopped (not paused) after a fault: the same.
        (_, c, probe) = try coordinator(root, "stopped")
        try c.start()
        c.captureFailed(busy)
        c.stop()
        for _ in 0..<2 { c.reconcileResume() }
        check(probe.healthy == 0, "stopped: good heartbeats after a stop never say saving works again", "healthy \(probe.healthy)")

        // 5. A late heartbeat refused a unit while recording (stale): the fault is noted; paused at once by the person,
        // a good heartbeat says nothing.
        (_, c, probe) = try coordinator(root, "stale")
        try c.start()
        c.captureFailed(MemError.invalid("Capture is not recording"))
        check(c.isRunning, "stale: a unit refused for a late heartbeat keeps recording")
        c.pause("Paused by you")
        c.reconcileResume()
        check(probe.healthy == 0, "stale: paused before the next heartbeat, it says nothing", "healthy \(probe.healthy)")

        if ddFailures > 0 { print("coordinator-healthy: \(passes) passed, \(ddFailures) failed"); exit(1) }
        print("coordinator-healthy: \(passes) passed, 0 failed. No app, event tap, permission or Accessibility read was used.")
    }
}
