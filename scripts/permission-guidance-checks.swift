// DD-RECIPE: UI
// perm-1004 (10/3: the permission flow was broken): what DayDream says and does while a permission
// is missing. Pure checks on MemoryUI (no window, no permission read, no System Settings, no relaunch):
//   A. Every surface names the missing permission ("Turn on Accessibility"), Accessibility first, and the one press
//      goes to that permission's pane.
//   B. Input Monitoring turned on after launch: DayDream restarts by itself once both read on, never in a loop.
//   C. Look-alike rows: the page names the exact row, and a row left from another copy is removed first, then added
//      again (tccd 10/3: a card dropped onto an existing row changes nothing).
//   D. Back twice from System Settings with both still off: the remove-and-add-again step comes first.
import AppKit
import MemoryCore
import MemoryUI

@MainActor enum Report {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ id: String, _ message: @autoclosure () -> String) {
        if ok { passed += 1; print("PASS [\(id)] \(message())") } else { failed += 1; print("FAIL [\(id)] \(message())") }
    }
}
@MainActor func check(_ ok: Bool, _ id: String, _ message: @autoclosure () -> String) { Report.check(ok, id, message()) }
@MainActor func equal<T: Equatable>(_ a: T, _ b: T, _ id: String, _ message: String) {
    Report.check(a == b, id, message + (a == b ? "" : " (got \(a), want \(b))"))
}

@MainActor @main struct PermissionGuidanceChecks {
    static func main() throws {
        let now = Date(), la = TimeZone(identifier: "America/Los_Angeles")!
        let ax = RecordingState.needsPermission(missing: [.accessibility])
        let im = RecordingState.needsPermission(missing: [.inputMonitoring])
        let both = RecordingState.needsPermission(missing: [.accessibility, .inputMonitoring])
        let unknown = RecordingState.needsPermission(missing: [])

        // MARK: A. The missing permission, named
        equal(PermissionKind.next([.inputMonitoring, .accessibility]), .accessibility, "A-name", "Accessibility is turned on first")
        equal(PermissionKind.next([]), nil, "A-name", "nothing named while nothing is known missing")
        equal(ax.capsuleLabel(now: now), "Turn on Accessibility", "A-name", "toolbar pill, Accessibility off")
        equal(im.capsuleLabel(now: now), "Turn on Input Monitoring", "A-name", "toolbar pill, Input Monitoring off")
        equal(both.capsuleLabel(now: now), "Turn on Accessibility", "A-name", "toolbar pill, both off: Accessibility first")
        equal(unknown.capsuleLabel(now: now), "Needs Permission", "A-name", "toolbar pill, which one unknown")
        equal(ax.menuBarAccessibilityLabel(now: now, timeZone: la), "DayDream: Turn on Accessibility", "A-name", "menu bar icon's VoiceOver label")
        equal(StatusCapsule.help(for: im, timeZone: la), "Input Monitoring is off in System Settings.", "A-name", "pill tooltip names it")
        equal(RecordingMasterControl.subtitle(ax), "Turn on Accessibility", "A-name", "Settings' recording switch line")
        equal(RecordingMasterControl.subtitle(both), "Turn on Accessibility · Input Monitoring is off too", "A-name",
              "Settings' recording switch line names both")
        equal(RecordingControls.buttons(for: ax).first?.title, "Turn on Accessibility", "A-name", "popover button")
        equal(RecordingControls.buttons(for: unknown).first?.title, "Allow Permissions", "A-name", "popover button, which one unknown")
        let header = MenuBarMenu.header(CapturePresentation(state: both), now: now, timeZone: la, canSetUp: true,
                                        canOpenApplications: false, canOpenPermissions: true)
        // int-015: one line beside the button (the panel never grows); the button names the permission, Settings' line both.
        equal(header.status.text, "2 permissions are off", "A-name", "menu bar line says both are off")
        equal(header.control, .fix(title: "Turn on Accessibility", fix: .permissions), "A-name", "menu bar button says what it turns on")
        let headerIM = MenuBarMenu.header(CapturePresentation(state: im), now: now, timeZone: la, canSetUp: false,
                                          canOpenApplications: false, canOpenPermissions: false)
        equal(headerIM.control, .fix(title: "Turn on Input Monitoring", fix: .systemSettings(.inputMonitoring)), "A-name",
              "menu bar without a DayDream window: straight to Input Monitoring's pane")
        let card = SettingsStatusCardModel(SettingsStatusSnapshot(state: im), calendar: Calendar.current, now: now)
        equal(card.stateLine, "Turn on Input Monitoring", "A-name", "Settings status line")
        // One press opens the named pane (both off: Accessibility's), never Privacy & Security's front page.
        var asked: [PermissionKind?] = []
        var actions = CaptureActions(); actions.openSystemSettings = { asked.append($0) }
        RecordingControls.perform(.openSystemSettings, actions: actions, state: both)
        RecordingControls.perform(.openSystemSettings, actions: actions, state: unknown,
                                  permissions: PermissionSnapshot(accessibility: true, inputMonitoring: false))
        equal(asked, [.accessibility, .inputMonitoring], "A-press", "the button opens the named permission's pane")
        let slot = StatusCapsule.slotWidth
        let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        let widest = ("Turn on Input Monitoring" as NSString).size(withAttributes: [.font: font]).width
        check(slot >= widest + 16 + 7, "A-pill", "the pill's fixed slot fits \"Turn on Input Monitoring\": slot \(slot), text \(widest)")
        let defaults = PermissionRequestActions(quitAndReopen: nil)
        check(defaults.paneRequest == nil && !defaults.autoRelaunch, "A-press", "no pane request and no restart unless the app sets one")

        // MARK: B. No manual restart
        func restarts(_ atLaunch: Bool?, settled: Bool = true, a: Bool? = true, i: Bool? = true, recording: Bool = false,
                      reopen: Bool = true, last: Date? = nil) -> Bool {
            PermissionRelaunch.restartsByItself(inputMonitoringAtLaunch: atLaunch, launchReadSettled: settled, accessibility: a,
                                                inputMonitoring: i, recording: recording, canReopen: reopen, lastAutoRestart: last, now: now)
        }
        check(restarts(false), "B-restart", "Input Monitoring off at launch, both on now: restarts by itself")
        check(!restarts(false, a: false), "B-restart", "…not while Accessibility is still off (one restart, once both are on)")
        check(!restarts(false, i: false), "B-restart", "…not while Input Monitoring still reads off")
        check(!restarts(true), "B-restart", "on at launch: no restart")
        check(!restarts(nil), "B-restart", "never read at launch: no restart")
        check(!restarts(false, settled: false), "B-restart", "an unconfirmed off read at launch (a blip): no restart")
        check(!restarts(false, recording: true), "B-restart", "never while recording")
        check(!restarts(false, reopen: false), "B-restart", "a development binary that can't reopen: no restart")
        check(!restarts(false, last: now.addingTimeInterval(-30)), "B-restart", "restarted 30 s ago: not again (no loop)")
        check(restarts(false, last: now.addingTimeInterval(-PermissionRelaunch.autoCooldown - 1)), "B-restart", "after the cooldown: again")
        check(PermissionRelaunch.autoText.contains("restarts by itself") && PermissionRelaunch.autoText.count <= 70, "B-restart",
              "one short line: \(PermissionRelaunch.autoText)")

        // MARK: C. Look-alike rows
        let out = URL(fileURLWithPath: ProcessInfo.processInfo.environment["DD_CHECK_OUT"] ?? NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("permission-guidance-\(getpid())", isDirectory: true)
        let app = out.appendingPathComponent("DayDream Live Test.app", isDirectory: true)
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "DayDream Live Test", "CFBundleIdentifier": "x.check"],
                                           format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        equal(PermissionRowHelp.appName(appURL: app), "DayDream Live Test", "C-rows", "the row's name is this copy's own")
        equal(PermissionRowHelp.appName(appURL: out.appendingPathComponent("Other.app")), "Other", "C-rows", "no Info.plist: the file name")
        let publicApp = URL(fileURLWithPath: "/Applications/DayDream.app"), oldApp = URL(fileURLWithPath: "/Volumes/X/live/DayDream.app")
        let copies: [String: [URL]] = ["com.getnorthlight.daydream": [publicApp, oldApp],
                                       "com.getnorthlight.daydream.livetest": [app, oldApp]]
        let found = PermissionRowHelp.lookAlikes(appURL: app, copies: { copies[$0] ?? [] })
        equal(found.map(\.path), [publicApp.path, oldApp.path], "C-rows", "other copies found, this one and duplicates left out")
        check(PermissionRowHelp.knownBundleIDs.contains("com.getnorthlight.daydream.livetest.adhoc"), "C-rows", "ad-hoc test IDs are looked for too")
        equal(PermissionRowHelp.rowLine(appName: "DayDream", otherCopies: 0), nil, "C-rows", "no other copy: no extra line")
        let line = PermissionRowHelp.rowLine(appName: "DayDream Live Test", otherCopies: 2) ?? ""
        check(line.contains("named exactly \u{201C}DayDream Live Test\u{201D}") && line.contains("minus"), "C-rows",
              "other copies: turn on the row named exactly this copy's name; old rows go with the minus button: \(line)")
        func before(_ text: String, _ a: String, _ b: String) -> Bool {
            guard let x = text.range(of: a), let y = text.range(of: b) else { return false }
            return x.lowerBound < y.lowerBound
        }
        let step = PermissionRowHelp.reAddStep(appName: "DayDream Live Test")
        check(step.contains("\u{201C}DayDream Live Test\u{201D}") && before(step, "minus", "drag the card") && step.contains("first"), "C-rows",
              "remove the row named this copy with the minus button first, then drag the card in again: \(step)")
        let hint = PermissionRowHelp.dragHint(appName: "DayDream Live Test")
        check(hint.contains("\u{201C}DayDream Live Test\u{201D}") && hint.contains("minus") && hint.contains("first"), "C-rows",
              "the drag hint names the row and says an existing row is removed first: \(hint)")
        let help = PermissionRowHelp.cardHelp(appName: "DayDream", permission: "Accessibility")
        check(before(help, "minus", "changes nothing") && help.contains("already listed"), "C-rows",
              "the card's tooltip: a row already there is removed first, dropping onto it changes nothing: \(help)")
        let recovery = PermissionGrantView.recoveryText(appName: "DayDream Live Test")
        check(before(recovery, "minus", "drag the card") && recovery.contains("changes nothing") && !recovery.contains("Quit and reopen"), "C-rows",
              "\"Already turned on in System Settings?\": remove, then add again; switching the old row on changes nothing: \(recovery)")

        // MARK: D. Back twice with both off
        var returns = PermissionReturns()
        returns.returned(paneOpened: false)
        check(!returns.showsReAddFirst(accessibility: false, inputMonitoring: false), "D-returns", "coming back without opening a pane doesn't count")
        returns.returned(paneOpened: true)
        check(!returns.showsReAddFirst(accessibility: false, inputMonitoring: false), "D-returns", "once back: not yet")
        returns.returned(paneOpened: true)
        check(returns.showsReAddFirst(accessibility: false, inputMonitoring: false), "D-returns", "twice back, both off: remove-and-add-again first")
        check(!returns.showsReAddFirst(accessibility: true, inputMonitoring: false), "D-returns", "one allowed: not shown")
        returns.reset()
        check(!returns.showsReAddFirst(accessibility: false, inputMonitoring: false), "D-returns", "a permission read on starts the count over")

        try? FileManager.default.removeItem(at: out)
        print("permission-guidance: \(Report.passed) passed, \(Report.failed) failed")
        exit(Report.failed == 0 ? 0 : 1)
    }
}
