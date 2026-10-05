// DD-RECIPE: APP
// claude/perf3-1005 (owner 10/04, "still laggy AF"): the app's periodic work never uses the history on the main thread.
// The laptop's sample showed the recorder's 0.5 s heartbeat writing the history on the main thread (a SQLite write
// transaction with its journal and fsync, 1 s of main-thread time in 30 s with a busy disk), and the status and typing
// refreshes after it reading it. Every main-thread stall over about 100 ms is a scroll hitch and, with the input tap
// handing keys to the main thread, a typing bug (a key seen more than 150 ms late is dropped).
//   A. `StoreMainThread` reports a statement run on the main thread (positive control: the synchronous heartbeat).
//   B. A recording production model (scratch history, permissions read as granted, no input tap) shown in a window:
//      ten heartbeats as the recorder's timer runs them (`reconcileResumeOffMain`), today's reread and a scroll of the
//      day's list run no statement on the main thread, and recording stays live.
//   C. The heartbeat writes the saved state only when it changed or its time is 2 s old: ten heartbeats in 4.5 s
//      write it at most three times, and the saved time is never older than 3.5 s (readers call 5 s expired).
// Setup on the main thread (the fixture's seeding, launch's open, the person's Start) is exempt (`StoreMainThread.allowed`).
// Synthetic data only, under DD_CHECK_OUT. No tap, no Keychain (typing keys in memory), no permission prompt.
import AppKit
import SwiftUI
import MemoryCore
import MemoryUI

func fail(_ message: String) -> Never {
    fflush(stdout)
    FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
    exit(1)
}
@MainActor func expect(_ condition: Bool, _ message: @autoclosure () -> String) { if !condition { fail(message()) } }
func pass(_ message: String) { print("PASS: \(message)"); fflush(stdout) }
@MainActor func pump(_ seconds: Double) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
@MainActor func wait(_ timeout: Double, _ done: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(timeout)
    while !done() && Date() < end { pump(0.02) }
    return done()
}

@main @MainActor enum StoreMainThreadGuardChecks {
    static func main() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
            FileHandle.standardError.write(Data("FAIL: store-main-thread-guard-checks watchdog expired after 120s\n".utf8))
            exit(2)
        }
        let shared = ["/private/tmp/" + "day" + "dream-", "/tmp/" + "day" + "dream-"]
        guard let outPath = ProcessInfo.processInfo.environment["DD_CHECK_OUT"], outPath.hasPrefix("/"),
              !shared.contains(where: { outPath.hasPrefix($0) }) else {
            fail("DD_CHECK_OUT is not a private output directory; run this check through run-checks.sh")
        }
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let root = URL(fileURLWithPath: outPath, isDirectory: true).appendingPathComponent("guard-" + UUID().uuidString, isDirectory: true)
        let memory = root.appendingPathComponent("memory", isDirectory: true)
        try! FileManager.default.createDirectory(at: memory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // A. The report, and its positive control.
        var used: [String] = []
        StoreMainThread.report = { used.append($0) }
        let control = try! StoreMainThread.allowed { try MemoryStore(home: root.appendingPathComponent("control"), writable: true, automaticallySyncSearch: false) }
        _ = try? control.policy()
        expect(used == ["SELECT"], "a read on the main thread is reported once, by its first word (got \(used))")
        used.removeAll()
        StoreMainThread.allowed { _ = try? control.policy() }
        expect(used.isEmpty, "a read inside StoreMainThread.allowed is not reported (got \(used))")
        let offMain = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { _ = try? control.policy(); offMain.signal() }
        offMain.wait()
        expect(used.isEmpty, "a read off the main thread is not reported (got \(used))")
        pass("the history used on the main thread is reported, by statement verb; allowed scopes and other threads are not")

        // B. A recording production model over a synthetic day.
        let now = Date()
        StoreMainThread.allowed {
            let seed = try! MemoryStore(home: memory, writable: true, automaticallySyncSearch: false)
            var at = Calendar.current.startOfDay(for: now).addingTimeInterval(9 * 3600)
            if at > now.addingTimeInterval(-3600) { at = now.addingTimeInterval(-3600) }
            let apps = [("Mail", "com.apple.mail"), ("Notes", "com.apple.Notes"), ("Terminal", "com.apple.Terminal"), ("Calendar", "com.apple.iCal")]
            for i in 0..<240 {
                let app = apps[(i / 6) % apps.count]
                _ = try? seed.ingest(Evidence(id: String(format: "guard-%04d", i), at: iso(at), kind: i % 6 == 0 ? "window.changed" : "mouse.click",
                                              app: app.0, bundle: app.1, title: "Fictional window \(i / 6)", synthetic: true), now: at.addingTimeInterval(1))
                at = at.addingTimeInterval(12)
            }
        }
        setenv("MAC_MEM_HOME", memory.path, 1)
        MemoryViewModel.permissionRead = { PermissionSnapshot(accessibility: true, inputMonitoring: true) }
        MemoryViewModel.permissionsGranted = { true }
        MemoryViewModel.startInput = { _ in true }
        MemoryViewModel.readLaunchLocation = { .applications }
        let model = StoreMainThread.allowed { MemoryViewModel() }
        // A check runner's Mac is often locked (unattended): the model would pause recording for the lock. It sees none.
        model.wakeSystem = WakeSystem(screenLocked: { false }, onConsole: { true }, after: WakeSystem.live.after, now: WakeSystem.live.now)
        StoreMainThread.allowed { model.startCapture() }
        expect(model.recording, "the check's model records (status: \(model.status))")
        guard let coordinator = model.coordinator else { fail("the model has no recorder") }
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 1000, height: 760), styleMask: [.borderless], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: MemoryWindow(model: model, chrome: .inline))
        window.contentView = host
        window.orderFrontRegardless()
        StoreMainThread.allowed { _ = wait(20) { model.activity.today.snapshot != nil } }
        expect(model.activity.today.snapshot != nil, "today's list loads")
        pump(0.5)
        let reader = try! StoreMainThread.allowed { try MemoryStore(home: memory) }
        func saved() -> (state: String, at: Date?) {
            let status = (try? StoreMainThread.allowed { try reader.captureStatus() }) ?? [:]
            return (status["state"] ?? "", timestamp(status["checked_at"] ?? ""))
        }

        used.removeAll()
        var times = Set<Date>(), oldest = 0.0
        for beat in 0..<10 {
            coordinator.reconcileResumeOffMain()
            pump(0.45)
            let s = saved()
            expect(s.state == "recording", "the saved state stays recording at heartbeat \(beat) (got \(s.state))")
            if let t = s.at { times.insert(t); oldest = max(oldest, Date().timeIntervalSince(t)) }
            if beat == 4 { model.activity.today.refresh(force: true) }
            if let scroll = scrollView(in: host) {
                let clip = scroll.contentView
                clip.scroll(to: NSPoint(x: 0, y: CGFloat(beat % 2) * 400)); scroll.reflectScrolledClipView(clip)
                host.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            }
        }
        pump(0.6)
        expect(model.recording, "recording stays on through the heartbeats (status: \(model.status))")
        expect(coordinator.beatsSkipped == 0, "no heartbeat was skipped on an idle disk (\(coordinator.beatsSkipped))")
        expect(used.isEmpty, "the heartbeat, the status and typing refreshes, today's reread and scrolling used the history on the main thread: \(used.count) statements (\(Set(used).sorted()))")
        pass("ten heartbeats, the status and typing refreshes, today's reread and a scroll of the list run no statement on the main thread")

        // C. Writes only when needed, and never stale.
        expect(times.count >= 2, "the heartbeat rewrote the saved time within 4.5 s (\(times.count) different times)")
        expect(times.count <= 4, "ten heartbeats over 4.5 s saved \(times.count) different times (written only every 2 s)")
        expect(oldest < 3.5, String(format: "the saved heartbeat was %.1f s old at most (under 3.5 s)", oldest))
        pass("an unchanged heartbeat writes nothing; the saved time is rewritten every 2 s and never older than 3.5 s")

        // The synchronous heartbeat (the checks' entry) still works on the main thread, and is reported there.
        used.removeAll()
        coordinator.reconcileResume()
        expect(!used.isEmpty, "the synchronous heartbeat on the main thread is reported (the guard sees main-thread use)")
        StoreMainThread.report = nil
        withExtendedLifetime((window, host, model)) {}
        print("store-main-thread-guard-checks passed")
        exit(0)
    }
    static func scrollView(in view: NSView) -> NSScrollView? {
        if let s = view as? NSScrollView, s.documentView != nil { return s }
        for v in view.subviews { if let s = scrollView(in: v) { return s } }
        return nil
    }
}
