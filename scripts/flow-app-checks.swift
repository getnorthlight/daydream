// DD-RECIPE: APP + scripts/harness/Timeline.swift
// Flows on the REAL MemoryViewModel and app delegate (scripts/harness/README.md, "APP flows"), with the check seams
// launch-state-checks uses: in-memory launch-intent defaults, fake lock and console reads and a fake notice center,
// permission reads answered by the seams (never asked of macOS), no event tap (`startInput` starts nothing), and a
// synthetic HOME and CFFIXED_USER_HOME. Nothing records outside a scratch store, nothing is sent (usage events stay in a
// scratch queue; check builds never send), no Apple event is sent or received (launch events are descriptors built here).
//
// [bug-1] (owner, 9/26: "Paused while your screen was locked." beside "couldn't save your history. Quit and reopen
//   DayDream", and recording never came back). The screen locks while DayDream records; DayDream hears the lock late
//   (AppKit held the notice) and its heartbeat was held back meanwhile, so the next save meets a stale heartbeat and the
//   store refuses it ("Capture is not recording"). That save is dropped and the heartbeat written again; the lock then
//   pauses recording with its own calm line only, and the unlock records again.
// [bug-9] (owner, 10/07: login launches counted as opens; 10/08: app_updated sent unknown). The launches of the launch
//   flows (scripts/fixtures/flows: login-launch-after-restart, update-relaunch, quit-and-reopen) through the app
//   delegate's own read of macOS's launch event, at the moment AppKit makes it current (applicationDidFinishLaunching;
//   it is not current yet in applicationWillFinishLaunching), the launch rules and the version read from the build's
//   Info.plist values, into the real usage queue.
//
// Usage: flow-app-checks <fixtures dir>
import AppKit
@testable import MemoryCore
import MemoryUI
import HistoryCore

@MainActor enum Report {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") {
        if ok { passed += 1; print("PASS \(label)") } else { failed += 1; print("FAIL \(label)\(detail().isEmpty ? "" : ": " + detail())") }
        fflush(stdout)
    }
}
@MainActor func check(_ ok: Bool, _ label: String, _ detail: @autoclosure () -> String = "") { Report.check(ok, label, detail()) }
func stop(_ message: String) -> Never { fflush(stdout); FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
@MainActor func tick(_ seconds: Double = 0.05) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
@MainActor func waitFor(_ seconds: Double, _ condition: () -> Bool) async throws -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end { if condition() { return true }; try await tick(0.05) }
    return condition()
}

/// Defaults kept in memory only (nothing reaches cfprefsd).
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    init(inMemory: Void = ()) { super.init(suiteName: nil)! }
    override func object(forKey k: String) -> Any? { values[k] }
    override func set(_ v: Any?, forKey k: String) { if let v { values[k] = v } else { values.removeValue(forKey: k) } }
    override func removeObject(forKey k: String) { values.removeValue(forKey: k) }
    override func dictionary(forKey k: String) -> [String: Any]? { values[k] as? [String: Any] }
    override func string(forKey k: String) -> String? { values[k] as? String }
    override func bool(forKey k: String) -> Bool { (values[k] as? NSNumber)?.boolValue ?? false }
    override func set(_ v: Bool, forKey k: String) { values[k] = v }
    override func double(forKey k: String) -> Double { (values[k] as? NSNumber)?.doubleValue ?? 0 }
    override func set(_ v: Double, forKey k: String) { values[k] = v }
    override func integer(forKey k: String) -> Int { (values[k] as? NSNumber)?.intValue ?? 0 }
    override func set(_ v: Int, forKey k: String) { values[k] = v }
}
@MainActor final class FakeNotices {
    var posted: [RecordingNotice] = []
    var center: RecordingNoticeCenter { RecordingNoticeCenter(prepare: {}, post: { self.posted.append($0) }, clear: {}) }
}
/// Lock and console reads, and the model's wake timers, held until the flow runs them.
@MainActor final class FakeWake {
    var locked = false, onConsole = true
    var pending: [(TimeInterval, () -> Void)] = []
    var system: WakeSystem {
        WakeSystem(screenLocked: { self.locked }, onConsole: { self.onConsole }, after: { delay, work in self.pending.append((delay, work)) }, now: { Date() })
    }
    @discardableResult func runPending() -> Int { let jobs = pending; pending = []; for (_, w) in jobs { w() }; return jobs.count }
}

@main @MainActor struct FlowAppChecks {
    static var out = URL(fileURLWithPath: "/")
    static let lockLine = "Paused while your screen was locked."

    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 240) {
            FileHandle.standardError.write(Data("FAIL: flow-app-checks watchdog expired after 240s\n".utf8)); exit(2)
        }
        let env = ProcessInfo.processInfo.environment
        guard CommandLine.arguments.count >= 2 else { stop("usage: flow-app-checks <fixtures dir>") }
        guard let outPath = env["DD_CHECK_OUT"], outPath.hasPrefix("/"), !outPath.hasPrefix("/private/tmp/"), !outPath.hasPrefix("/tmp/") else {
            stop("DD_CHECK_OUT is not a private output directory; run this check through run-checks.sh")
        }
        guard let fixed = env["CFFIXED_USER_HOME"], env["HOME"] == fixed, fixed != "/Users/" + NSUserName(),
              FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path == URL(fileURLWithPath: fixed).standardizedFileURL.path else {
            stop("HOME and CFFIXED_USER_HOME must name one synthetic home; run this check through run-checks.sh")
        }
        out = URL(fileURLWithPath: outPath, isDirectory: true).appendingPathComponent("flow-app", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        MemoryViewModel.permissionsGranted = { true }
        MemoryViewModel.permissionRead = { PermissionSnapshot(accessibility: true, inputMonitoring: true) }
        MemoryViewModel.startInput = { _ in true }
        MemoryViewModel.readLaunchLocation = { .applications }
        MemoryViewModel.canReopen = { true }
        UserDefaults.standard.register(defaults: [MemoryViewModel.setupCompletedKey: true])

        try await lockHeardLateAfterAStaleSave()
        try await lockHeardOnTime()
        try await lockNeverHeard()
        try launches(URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true))

        print("flow-app: \(Report.passed) passed, \(Report.failed) failed")
        fflush(stdout)
        exit(Report.failed == 0 ? 0 : 1)
    }

    // MARK: bug 1

    struct Opened { let model: MemoryViewModel; let notices: FakeNotices; let wake: FakeWake; let home: URL }
    static func open(_ name: String) async throws -> Opened {
        let home = out.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        setenv("MAC_MEM_HOME", home.path, 1)
        MemoryViewModel.launchIntentDefaults = MemoryDefaults()
        let model = MemoryViewModel()
        MemoryViewModel.launchIntentDefaults = nil
        let notices = FakeNotices(), wake = FakeWake()
        model.noticeCenter = notices.center
        model.wakeSystem = wake.system
        _ = try await waitFor(3) { !model.history.busy }
        try await tick(0.1)
        return Opened(model: model, notices: notices, wake: wake, home: home)
    }
    static func reason(_ o: Opened) -> String? {
        if case .paused(_, _, let reason) = o.model.recordingState { return reason }
        return nil
    }
    static func describe(_ o: Opened) -> String {
        "\(o.model.recordingState), session \(o.model.coordinator?.session.state ?? "none")/\(o.model.coordinator?.session.reason ?? ""), notices \(o.notices.posted.map(\.body))"
    }
    /// Every line the menu bar and the window could show for the state now (the header's title and detail).
    static func lines(_ o: Opened) -> String {
        let h = MenuBarMenu.header(o.model.presentation, now: Date(), timeZone: TimeZone(identifier: "America/Chicago")!, canSetUp: true, canOpenApplications: false)
        return "\(h) \(reason(o) ?? "")"
    }
    static func unlock(_ o: Opened) async throws {
        o.wake.locked = false
        o.model.unsuspend(.screenLock)
        var n = 0
        while !o.model.recording && !o.wake.pending.isEmpty && n < 8 { try await tick(0.1); o.wake.runPending(); n += 1 }
        try await tick(0.1)
    }
    static func textEdit() -> AccessibilitySnapshot {
        AccessibilitySnapshot(focusID: "flow-field", app: AppInfo(name: "TextEdit", bundleIdentifier: "com.apple.TextEdit"),
                              window: WindowInfo(title: "plan.txt", url: nil), element: ElementInfo(role: "AXTextArea"),
                              secureInput: false, privateBrowsing: false, selectedText: nil, selectedLocation: nil, selectedLength: nil)
    }

    static func lockHeardLateAfterAStaleSave() async throws {
        let o = try await open("lock-late")
        o.model.startCapture()
        guard o.model.recording, let coordinator = o.model.coordinator else { check(false, "[bug-1] lock-heard-late: recording started", describe(o)); return }
        // The display sleeps before the screen locks: App Nap holds the recorder's heartbeat back (here: no heartbeat
        // runs at all), past the store's 5 s limit (real seconds: the store's clock is real time).
        try await tick(5.6)
        // A save lands then: an app switch the recorder saw just before. A metadata save like this one is not held to
        // the heartbeat (the store keeps it: measured 10/08, records 0 -> 1 with the capture status "unavailable"), so on
        // its own it never reached the refusal this flow is about. The refusal itself is what the store throws for a
        // typed unit while the heartbeat is stale (MemoryStore.ingest, requireRecording: "Capture is not recording"),
        // handed to the coordinator the way CoreCaptureBinding hands it (captureFailed, recording at the time).
        coordinator.record(kind: .appActivated, snapshot: textEdit())
        coordinator.captureFailed(MemError.invalid("Capture is not recording"), recording: true)
        try await tick(0.2)
        check(o.model.recording && coordinator.session.state == "recording" && !lines(o).lowercased().contains("couldn't save"),
              "[bug-1] lock-heard-late: a save refused for a late heartbeat is dropped and recording goes on (never \"couldn't save\")", describe(o))
        // The screen locks, and DayDream hears it (late).
        o.wake.locked = true
        o.model.suspend(.screenLock)
        try await tick(0.1)
        let shown = lines(o)
        check(reason(o) == lockLine && !shown.contains(RecordingCopy.savingFailed) && !shown.lowercased().contains("couldn't save"),
              "[bug-1] lock-heard-late: the lock shows its own calm line only, never \"couldn't save\" beside it", "\(shown); \(describe(o))")
        check(o.notices.posted.isEmpty, "[bug-1] lock-heard-late: nothing is said while the screen is locked", describe(o))
        try await unlock(o)
        check(o.model.recording && coordinator.session.state == "recording", "[bug-1] lock-heard-late: the unlock records again", describe(o))
        // And the next save lands.
        func saved() -> String { (try? MemoryStore(home: o.home, writable: false, automaticallySyncSearch: false).rows("SELECT count(*) FROM records").first?.first) ?? "-" }
        let before = saved()
        o.model.coordinator?.record(kind: .appActivated, snapshot: textEdit())
        try await tick(0.1)
        let after = saved()
        check(before != after, "[bug-1] lock-heard-late: the first save after the unlock is kept", "\(before) -> \(after)")
        o.model.stopCapture()
    }

    /// The lock's notice never comes (AppKit held it while DayDream was in the background): recording must still stop
    /// behind the lock screen, with the lock's own line, and the unlock record again.
    static func lockNeverHeard() async throws {
        let o = try await open("lock-unheard")
        o.model.startCapture()
        guard o.model.recording else { check(false, "[bug-1] lock-unheard: recording started", describe(o)); return }
        o.wake.locked = true
        _ = try await waitFor(4) { !o.model.recording }
        check(!o.model.recording && reason(o) == lockLine && !lines(o).lowercased().contains("couldn't save"),
              "[bug-1] lock-unheard: a lock whose notice never comes still pauses recording within seconds, with the lock's own line", describe(o))
        try await unlock(o)
        check(o.model.recording && o.notices.posted.isEmpty, "[bug-1] lock-unheard: the unlock records again, nothing said", describe(o))
        o.model.stopCapture()
    }

    static func lockHeardOnTime() async throws {
        let o = try await open("lock-on-time")
        o.model.startCapture()
        guard o.model.recording else { check(false, "[bug-1] lock-on-time: recording started", describe(o)); return }
        o.wake.locked = true
        o.model.suspend(.screenLock)
        try await tick(0.1)
        check(reason(o) == lockLine && !lines(o).lowercased().contains("couldn't save"), "[bug-1] lock-on-time: paused for the lock with its own line", describe(o))
        try await tick(5.6)  // locked a while: no heartbeat, no save
        try await unlock(o)
        check(o.model.recording && o.notices.posted.isEmpty, "[bug-1] lock-on-time: the unlock records again, nothing said", describe(o))
        o.model.stopCapture()
    }

    // MARK: bug 9

    /// macOS's launch event for a fixture launch: an open-application event, a login item's carrying
    /// keyAELaunchedAsLogInItem; "no-open-event" has none. Built here, never sent.
    static func launchEvent(_ how: String) -> NSAppleEventDescriptor? {
        guard how != "no-open-event" else { return nil }
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEOpenApplication), targetDescriptor: nil,
                                           returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if how == "login" { event.setParam(NSAppleEventDescriptor(enumCode: OSType(keyAELaunchedAsLogInItem)), forKeyword: AEKeyword(keyAEPropData)) }
        return event
    }

    static func launches(_ dir: URL) throws {
        // AppKit makes the launch event current in applicationDidFinishLaunching, not before (applicationWillFinishLaunching
        // still sees none): the event the delegate reads is the one current at the hook it implements.
        let delegate = DaydreamAppDelegate()
        let atDidFinish = delegate.responds(to: #selector(NSApplicationDelegate.applicationDidFinishLaunching(_:)))
        let atWillFinish = delegate.responds(to: #selector(NSApplicationDelegate.applicationWillFinishLaunching(_:)))
        check(atDidFinish && !atWillFinish, "[bug-9] launches: DayDream reads its launch event in applicationDidFinishLaunching, where macOS has made it current",
              "didFinish \(atDidFinish), willFinish \(atWillFinish)")
        for name in ["login-launch-after-restart", "update-relaunch", "quit-and-reopen"] {
            let t = try Timeline.load(dir.appendingPathComponent(name + ".json"))
            let defaults = MemoryDefaults()
            if t.install?.kind == "upgrade" { defaults.set(t.install?.from ?? "", forKey: UsageLaunch.lastRunKey) }
            let home = out.appendingPathComponent("usage-" + name, isDirectory: true)
            try? FileManager.default.removeItem(at: home)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let sender = UsageSender(defaults: defaults)
            sender.start(home: home)
            var first = t.install?.kind != "upgrade"
            for (i, e) in t.events.enumerated() {
                if e.op == .quit, let next = t.events[(i + 1)...].first(where: { $0.op == .launch }),
                   next.how == "update-relaunch" || next.how == "self-relaunch" {
                    UsageLaunch.markSelfRelaunch(defaults)  // Sparkle's relaunch and Quit & Reopen leave the one-use mark
                }
                guard e.op == .launch else { continue }
                let kind = DaydreamAppDelegate.launchKind(atDidFinish ? launchEvent(e.how ?? "opened") : nil)
                if let how = UsageLaunch.launchOpen(kind, selfRelaunch: UsageLaunch.takeSelfRelaunch(defaults)) { sender.record("app_opened", ["how": .text(how)]) }
                let version = e.version ?? "0.1.8 Beta (20261008120000)"
                let short = version.components(separatedBy: " (").first, build = version.components(separatedBy: " (").last.map { String($0.dropLast()) }
                if let update = UsageLaunch.takeUpdate(defaults, current: UsageLaunch.version(short: short, build: build), newInstall: first) {
                    sender.record("app_updated", ["from_version": .text(update.from), "to_version": .text(update.to)])
                }
                first = false
            }
            let queued = sender.recent.reversed().map(\.event)
            let opened = queued.filter { $0.name == "app_opened" }.count
            let updates = queued.filter { $0.name == "app_updated" }.map { [$0.properties["from_version"], $0.properties["to_version"]].map { v -> String in
                if case .text(let s)? = v { return s }; return "-" } }
            let asked = t.events.filter { $0.op == .launch && $0.how == "opened" }.count
            check(opened == asked, "[bug-9] \(name): app_opened is queued once for each launch the person asked for, never for a login launch or a relaunch",
                  "queued \(opened), want \(asked)")
            if let want = t.expect?.updated {
                check(updates == want, "[bug-9] \(name): app_updated is queued with the release versions it updated from and to", "queued \(updates), want \(want)")
            }
        }
    }
}
