// DD-RECIPE: APP
// Capture input on real MemoryViewModel instances (golden test 5). Private stores under DD_CHECK_OUT, HOME and
// CFFIXED_USER_HOME in scratch, a fake clock and scheduler for the wake rules, fake notices. Permission reads go
// through `MemoryViewModel.permissionRead` and `permissionsGranted` only; nothing records, prompts, relaunches or opens a
// window: no check here calls startCapture or requestStart, and no wake settle is run.
//   G32  Input Monitoring turned on while DayDream runs (off at launch, or turned off and on again): every Start control
//        goes to setup's Permissions page, whose one button is then Quit & Reopen. One off read that is on again
//        1.5 s later changes nothing, and neither do reads while the screen is locked.
//   G3   The input tap that couldn't be turned back on or made again: recording stays wanted, one notice says why,
//        and the wake rules start it again after the next lock or sleep (was: it stayed off for good).
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
func pass(_ message: String) { print("PASS " + message); fflush(stdout) }
@MainActor func tick(_ seconds: Double = 0.05) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
func makePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

@MainActor final class FakeNotices {
    var posted: [RecordingNotice] = []
    var center: RecordingNoticeCenter { RecordingNoticeCenter(prepare: {}, post: { self.posted.append($0) }, clear: {}) }
}
@MainActor final class FakeWake {
    var pending: [(TimeInterval, () -> Void)] = []
    var system: WakeSystem {
        WakeSystem(screenLocked: { false }, onConsole: { true }, after: { delay, work in self.pending.append((delay, work)) },
                   now: { Date(timeIntervalSince1970: 1_790_000_000) })
    }
}

@main @MainActor struct CaptureInputModelChecks {
    /// What the substituted permission read says: Accessibility stays on; Input Monitoring follows this.
    static var inputMonitoring = true
    static var out: URL!

    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 90) {
            FileHandle.standardError.write(Data("FAIL: capture-input-model-checks watchdog expired after 90s\n".utf8))
            exit(2)
        }
        let shared = ["/private/tmp/" + "day" + "dream-", "/tmp/" + "day" + "dream-"]
        guard let outPath = ProcessInfo.processInfo.environment["DD_CHECK_OUT"], outPath.hasPrefix("/"),
              !shared.contains(where: { outPath.hasPrefix($0) }) else {
            fail("DD_CHECK_OUT is not a private output directory; run this check through run-checks.sh")
        }
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        guard home == ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"],
              !home.isEmpty, home != (getpwuid(getuid()).flatMap { String(cString: $0.pointee.pw_dir) } ?? "") else {
            fail("HOME is not a scratch folder (UserDefaults and the setup flag must stay out of the real account): \(home)")
        }
        out = URL(fileURLWithPath: outPath, isDirectory: true).appendingPathComponent("capture-input-model", isDirectory: true)
        try makePrivateDirectory(out)
        MemoryViewModel.permissionRead = { PermissionSnapshot(accessibility: true, inputMonitoring: inputMonitoring) }
        MemoryViewModel.permissionsGranted = { inputMonitoring }
        MemoryViewModel.canReopen = { true }
        UserDefaults.standard.set(true, forKey: MemoryViewModel.setupCompletedKey)

        try await turnedOnAfterLaunch()
        try await turnedOffAndOnAgain()
        try await blip()
        try await whileLocked()
        try await cannotReopen()
        try await inputTapStop()
        pass("all capture-input model checks: no model recorded; no prompt, relaunch, notification or window")
    }

    static func model(_ name: String) async throws -> (MemoryViewModel, FakeNotices, FakeWake) {
        let memory = out.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try makePrivateDirectory(memory)
        setenv("MAC_MEM_HOME", memory.path, 1)
        MemoryViewModel.readLaunchLocation = { .applications }
        let model = MemoryViewModel()
        MemoryViewModel.readLaunchLocation = { LaunchLocation.read() }
        let notices = FakeNotices(), wake = FakeWake()
        model.noticeCenter = notices.center
        model.wakeSystem = wake.system
        try await tick()
        expect(model.preferencesAvailable && model.development == nil, "\(name): the private store did not open: \(model.status)")
        expect(!model.recording, "\(name): the model is recording")
        return (model, notices, wake)
    }
    /// Where the model's Start controls go now, with nothing else in the way (setup done, choices saved).
    static func startStep(_ model: MemoryViewModel) -> DaydreamOnboardingPage? { model.setupStepForStart() }

    // MARK: G32

    static func turnedOnAfterLaunch() async throws {
        inputMonitoring = false
        let (model, _, _) = try await model("im-off-at-launch")
        expect(startStep(model) == .permissions, "setup: with Input Monitoring off, Start goes to Permissions")
        // The person turns it on in System Settings, seconds after launch. (An off read at launch that reads on again
        // within InputMonitoringWatch.confirmAfter was a moment's "not allowed": gold/int final review, G33.)
        try await tick(InputMonitoringWatch.confirmAfter + 0.2)
        model.checkPermissions()
        inputMonitoring = true
        model.checkPermissions()
        expect(model.permissionSnapshot.inputMonitoring == true, "setup: the model reads Input Monitoring on now")
        expect(startStep(model) == .permissions,
               "G32: Input Monitoring turned on after launch: Start goes to Permissions (was: Start ran and the tap failed): \(String(describing: startStep(model)))")
        expect(model.permissionRequests?.inputMonitoringAtLaunch == false
               && PermissionRelaunch.reason(inputMonitoringAtLaunch: model.permissionRequests?.inputMonitoringAtLaunch, accessibility: true, inputMonitoring: true) == .inputMonitoringTurnedOn,
               "G32: the Permissions page then offers its one fix, Quit & Reopen")
        pass("G32: Input Monitoring turned on after launch: every Start control goes to Permissions, which offers Quit & Reopen")
    }

    static func turnedOffAndOnAgain() async throws {
        inputMonitoring = true
        let (model, _, _) = try await model("im-revoked")
        expect(startStep(model) == nil, "setup: with both permissions on at launch, Start starts (not called here): \(String(describing: startStep(model)))")
        inputMonitoring = false
        model.checkPermissions()
        try await tick(InputMonitoringWatch.confirmAfter + 0.4)
        inputMonitoring = true
        model.checkPermissions()
        expect(startStep(model) == .permissions,
               "G32: Input Monitoring turned off, then on again while DayDream runs: Start goes to Permissions (was: Start ran with a tap macOS won't feed): \(String(describing: startStep(model)))")
        expect(model.permissionRequests?.inputMonitoringAtLaunch == false, "G32: the Permissions page offers Quit & Reopen for it too")
        pass("G32: Input Monitoring turned off and on again while DayDream runs: Start goes to Permissions, which offers Quit & Reopen")
    }

    static func blip() async throws {
        inputMonitoring = true
        let (model, _, _) = try await model("im-blip")
        inputMonitoring = false
        model.checkPermissions()
        inputMonitoring = true
        try await tick(InputMonitoringWatch.confirmAfter + 0.4)
        model.checkPermissions()
        expect(startStep(model) == nil && model.permissionRequests?.inputMonitoringAtLaunch == true,
               "G32: one off read that is on again 1.5 s later changes nothing: \(String(describing: startStep(model)))")
        pass("G32: a single off read (on again at the confirming read) never sends Start to Quit & Reopen")
    }

    static func whileLocked() async throws {
        inputMonitoring = true
        let (model, _, _) = try await model("im-locked")
        model.suspend(.screenLock)
        inputMonitoring = false
        model.checkPermissions()
        try await tick(InputMonitoringWatch.confirmAfter + 0.4)
        inputMonitoring = true
        model.unsuspend(.screenLock)
        model.checkPermissions()
        expect(startStep(model) == nil && model.permissionRequests?.inputMonitoringAtLaunch == true,
               "G32: off reads while the screen is locked don't count: \(String(describing: startStep(model)))")
        pass("G32: off reads while the screen is locked don't count")
    }

    static func cannotReopen() async throws {
        MemoryViewModel.canReopen = { false }
        defer { MemoryViewModel.canReopen = { true } }
        inputMonitoring = false
        let (model, _, _) = try await model("im-no-reopen")
        inputMonitoring = true
        model.checkPermissions()
        expect(startStep(model) == nil, "G32: where DayDream can't reopen itself (not an app bundle), Start isn't sent to a page with no button for it")
        pass("G32: without a way to reopen, Start keeps its old path")
    }

    // MARK: G3 (last: it leaves the model suspended)

    static func inputTapStop() async throws {
        inputMonitoring = true
        let (model, notices, wake) = try await model("input-tap")
        guard let coordinator = model.coordinator else { fail("the input-tap model has no coordinator") }
        model.noteRecording(true)
        expect(model.recordingWanted, "setup: a start marks recording as wanted")
        // EventCapture.tapDisabled: the tap couldn't be turned back on or made again (capture-input-checks drives that part).
        try coordinator.session.pause("Input tap was disabled. Resume explicitly.")
        model.noteRecording(false)
        try await tick()
        expect(model.recordingWanted, "G3: a stop because the input tap was lost keeps recording wanted (was: dropped, so nothing started it again)")
        // gold/r2-copy-checks: the menu bar's words for it (recording-wake-checks pins the whole text for each state).
        expect(notices.posted.count == 1 && notices.posted[0].body.contains("because DayDream can't see your keys or clicks.")
               && model.stopNotice == notices.posted.first,
               "G3: one notice says why: \(notices.posted.map(\.body))")
        model.suspend(.screenLock)
        expect(model.wake.plan == .record, "G3: after the next lock the wake rules plan to start recording again: \(model.wake.plan)")
        expect(!model.recording && wake.pending.isEmpty, "G3: nothing started here (the settle runs after the unlock)")
        pass("G3: a lost input tap keeps recording wanted: one notice, and the wake rules start it again after the next lock or sleep")
    }
}
