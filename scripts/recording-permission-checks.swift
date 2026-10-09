// DD-RECIPE: SRC Sources/MacMemApp/PermissionRequests.swift Sources/MacMemApp/LaunchLocation.swift + MemoryUI objects
//
// SPEC 6.3 R2: the permission page (the owner's drag cards). Every macOS call is stubbed: the check never
// shows a prompt, opens System Settings, relaunches or quits another app. The quit checks quit only child
// copies of this check.
//   A. DayDream never asks macOS for a permission: no source calls a request API, the page has no Allow
//      button, and each missing card opens its own System Settings pane or drags DayDream into its list.
//   B. Quit & Reopen starts the relaunch helper for the app bundle, then quits; never for a non-app,
//      never quits when the helper didn't start. The helper takes the pid and path as arguments, waits for
//      DayDream to quit, then opens it (checked with echo standing in for open). rc-018 RC3 (A6): the restart says
//      whether it started; a DayDream still running after the wait is never opened over; a background restart opens
//      with open -g. Every window here stays offscreen (`OffscreenWindow`).
//   C. Quit & Reopen shows only when macOS needs DayDream to reopen (PermissionRelaunch), and pressing it
//      in the laid-out page runs the injected launcher, then the quit.
//   D. AppQuit quits while a sheet is attached (a child copy of this check with the Settings-style sheet,
//      an alert on it, and a SwiftUI sheet); the bare NSApp.terminate stays put, which is why AppQuit exists.
//      End to end: Quit & Reopen from under a sheet quits the child, and the helper then "opens" the app.
//   E. From the download window the cards don't drag or open, the move warning shows and its button
//      opens /Applications.
//   F. Sources: the page reads status live (no Check Again, no "Checked" line, no intro sentence, no
//      "How DayDream uses them"), and every quit path in the app goes through AppQuit.
//   G. PermissionGrantView renders (cards and Settings, missing/allowed/relaunch, download window), light
//      and dark, into DD_CHECK_OUT for review.
import AppKit
import SwiftUI
import MemoryUI

/// rc-018 RC3: windows here stay off every screen (AppKit pulls a titled window ordered in at -4000 back onto the screen
/// unless it refuses, as chrome-ask-checks' KeyWindow does).
final class OffscreenWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
    /// macOS 26 already moves a window made at -4000 onto the screen in `init` (480,160 on this Mac, probe 10/9), before
    /// `constrainFrameRect` is ever asked: put it back off screen right away (a window asked for on screen, as a sheet's
    /// placeholder at 0,0, goes to -5000 too; AppKit places an attached sheet by its off-screen parent).
    override init(contentRect: NSRect, styleMask: NSWindow.StyleMask, backing: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: styleMask, backing: backing, defer: flag)
        let off = contentRect.minX <= -1000 && contentRect.minY <= -1000 ? contentRect.origin : NSPoint(x: -5000, y: -5000)
        setFrameOrigin(off)
    }
}
// Collect, then report: a failed check prints FAIL and the run goes on; the process exits 1 at the end if any failed
// (an atexit handler, so every return path of main reports). stdout is line-buffered so FAIL lines survive a crash.
var ddFailures = 0
func ddFail(_ label: String) { ddFailures += 1; print("FAIL " + label) }
func ddReportAtExit() {
    setvbuf(stdout, nil, _IOLBF, 0)
    atexit { if ddFailures > 0 { print("\(ddFailures) failed"); fflush(stdout); _exit(1) } }
}

@MainActor @main enum RecordingPermissionChecks {
    static var passes = 0
    static var failures: [String] = []
    nonisolated(unsafe) static var finished = false
    // Every check runs and every failure is reported (no fail-fast that hides the checks after it); the run exits
    // non-zero at the end if any failed.
    static func check(_ ok: Bool, _ name: String) {
        guard ok else { failures.append(name); ddFail(name); return }
        passes += 1; print("PASS " + name); fflush(stdout)
    }

    final class Recorder {
        var calls: [String] = []
        var relaunchWorks = true
        func env(bundle: String = "/Applications/DayDream.app", background: Bool = false) -> PermissionRequestEnvironment {
            PermissionRequestEnvironment(
                open: { self.calls.append("open " + $0.absoluteString); return true },
                relaunch: { app, pid in self.calls.append("relaunch \(app.path) \(pid)"); return self.relaunchWorks },
                relaunchInBackground: background ? { app, pid in self.calls.append("background \(app.path) \(pid)"); return self.relaunchWorks } : nil,
                terminate: { self.calls.append("terminate") },
                bundleURL: URL(fileURLWithPath: bundle), pid: 4242)
        }
    }

    static func main() async throws {
        ddReportAtExit()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--quit-child"), i + 1 < args.count {
            quitChild(args[i + 1], extra: i + 2 < args.count ? args[i + 2] : nil)
        }
        // A run that ends before the last check (the async main's run loop returning early, an exit elsewhere) is a
        // failure, never a silent exit 0 that skips the checks after it.
        atexit {
            guard !RecordingPermissionChecks.finished else { return }
            FileHandle.standardError.write(Data("FAIL: recording-permission-checks exited before all checks ran (\(RecordingPermissionChecks.passes) passed)\n".utf8))
            _exit(1)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 240) {
            FileHandle.standardError.write(Data("FAIL: recording-permission-checks watchdog expired after 240s\n".utf8)); exit(2)
        }
        wiring()
        relaunchReasons()
        helperScript()
        helperStillRunning()
        quitWithSheet()
        sources()
        try await pageButtons()
        try await renders()
        finished = true
        guard failures.isEmpty else {
            FileHandle.standardError.write(Data("FAIL: \(failures.count) of \(passes + failures.count) recording-permission checks failed:\n".utf8))
            for name in failures { FileHandle.standardError.write(Data("  - \(name)\n".utf8)) }
            exit(1)
        }
        print("PASS all \(passes) recording-permission checks")
    }

    // MARK: B, E. The actions

    static func wiring() {
        var r = Recorder()
        var actions = PermissionRequests.actions(r.env(), location: .applications)
        check(actions.moveWarning == nil && actions.moveDetail == nil && actions.inputMonitoringAtLaunch == nil, "no move warning from Applications")
        check(PermissionKind.settingsURL(.accessibility).absoluteString.hasSuffix("?Privacy_Accessibility")
              && PermissionKind.settingsURL(.inputMonitoring).absoluteString.hasSuffix("?Privacy_ListenEvent"),
              "each permission has its own pane")
        check(PermissionRequests.actions(r.env(), location: .applications, inputMonitoringAtLaunch: false).inputMonitoringAtLaunch == false,
              "the app hands the page its launch read of Input Monitoring")

        // B. Quit & Reopen
        r = Recorder(); actions = PermissionRequests.actions(r.env(), location: .applications)
        check(actions.quitAndReopen != nil, "an app bundle gets Quit & Reopen")
        actions.quitAndReopen?()
        check(r.calls == ["relaunch /Applications/DayDream.app 4242", "terminate"], "Quit & Reopen starts the helper, then quits: \(r.calls)")
        r = Recorder(); r.relaunchWorks = false; actions = PermissionRequests.actions(r.env(), location: .applications)
        actions.quitAndReopen?()
        check(r.calls == ["relaunch /Applications/DayDream.app 4242"], "no quit when the helper couldn't start: \(r.calls)")
        r = Recorder(); actions = PermissionRequests.actions(r.env(bundle: "/Volumes/Work/build/debug"), location: .notAnApp)
        check(actions.quitAndReopen == nil && r.calls.isEmpty, "a development binary gets no Quit & Reopen: \(r.calls)")
        let args = PermissionRequests.relaunchArguments(app: URL(fileURLWithPath: "/Applications/Day Dream's.app"), pid: 77)
        check(PermissionRequests.relaunchShell == "/bin/sh" && args == ["-c", PermissionRequests.relaunchScript, "daydream-relaunch", "77", "/Applications/Day Dream's.app"],
              "the helper gets the pid and path as arguments, never pasted into the script")
        check(PermissionRequests.relaunchScript.contains("kill -0 \"$1\"") && PermissionRequests.relaunchScript.contains("exec /usr/bin/open \"$2\"")
              && PermissionRequests.relaunchScript.contains("$i -lt 150"), "the helper waits (bounded) for DayDream to quit, then opens it")
        let syntax = Process()
        syntax.executableURL = URL(fileURLWithPath: "/bin/sh"); syntax.arguments = ["-n", "-c", PermissionRequests.relaunchScript]
        try? syntax.run(); syntax.waitUntilExit()
        check(syntax.terminationStatus == 0, "the helper script parses (sh -n; nothing runs)")
        // rc-018 RC3 (A6): the restart says whether it started; a background restart opens with open -g; a DayDream still
        // running after the wait is never opened over.
        r = Recorder()
        check(PermissionRequests.quitAndReopen(r.env()) && r.calls == ["relaunch /Applications/DayDream.app 4242", "terminate"],
              "A6 quitAndReopen starts the helper, quits, and says it did: \(r.calls)")
        r = Recorder(); r.relaunchWorks = false
        check(!PermissionRequests.quitAndReopen(r.env()) && r.calls == ["relaunch /Applications/DayDream.app 4242"],
              "A6 a helper that couldn't start: false, and nothing quits: \(r.calls)")
        r = Recorder()
        check(!PermissionRequests.quitAndReopen(r.env(bundle: "/Volumes/Work/build/debug")) && r.calls.isEmpty,
              "A6 a development binary: false, no helper, no quit: \(r.calls)")
        r = Recorder()
        check(PermissionRequests.quitAndReopen(r.env(background: true), background: true) && r.calls == ["background /Applications/DayDream.app 4242", "terminate"],
              "A6 a background restart starts the background helper: \(r.calls)")
        let bargs = PermissionRequests.relaunchArguments(app: URL(fileURLWithPath: "/Applications/DayDream.app"), pid: 77, background: true)
        check(bargs == ["-c", PermissionRequests.backgroundRelaunchScript, "daydream-relaunch", "77", "/Applications/DayDream.app"]
              && PermissionRequests.backgroundRelaunchScript.contains("exec /usr/bin/open -g \"$2\"")
              && !PermissionRequests.relaunchScript.contains("open -g"),
              "A6 the background helper opens with open -g (no window comes forward); the setup one doesn't")
        for (name, script) in [("setup", PermissionRequests.relaunchScript), ("background", PermissionRequests.backgroundRelaunchScript)] {
            check(script.contains("done; /bin/kill -0 \"$1\" 2>/dev/null && exit 0; exec /usr/bin/open"),
                  "A6 the \(name) helper ends without opening anything while DayDream still runs after the wait")
        }

        // E. The download window
        for location in [LaunchLocation.diskImage, .translocated] {
            r = Recorder(); actions = PermissionRequests.actions(r.env(bundle: "/Volumes/DayDream/DayDream.app"), location: location)
            check(actions.moveWarning == "Move DayDream to Applications first." && actions.moveDetail == LaunchLocation.detail,
                  "the move warning shows (\(location))")
            actions.openApplications()
            check(r.calls == ["open file:///Applications/"], "Open Applications Folder opens /Applications: \(r.calls)")
        }
        let app = URL(fileURLWithPath: "/Applications/DayDream.app")
        check(PermissionDragPayload.writer(appURL: app, enabled: true) as URL? == app
              && PermissionDragPayload.writer(appURL: app, enabled: false) == nil
              && PermissionDragPayload.writer(appURL: URL(fileURLWithPath: "/Volumes/Work/build/debug/MacMem"), enabled: true) == nil,
              "a card drags the app bundle only: never from the download window or for a development binary")
    }

    // MARK: C. When the page offers Quit & Reopen

    static func relaunchReasons() {
        typealias R = PermissionRelaunch
        check(R.reason(inputMonitoringAtLaunch: false, accessibility: true, inputMonitoring: true) == .inputMonitoringTurnedOn
              && R.reason(inputMonitoringAtLaunch: false, accessibility: false, inputMonitoring: true) == .inputMonitoringTurnedOn,
              "Input Monitoring off at launch and on now: Quit & Reopen (macOS needs it)")
        check(R.reason(inputMonitoringAtLaunch: true, accessibility: true, inputMonitoring: true) == nil
              && R.reason(inputMonitoringAtLaunch: nil, accessibility: true, inputMonitoring: true) == nil
              && R.reason(inputMonitoringAtLaunch: false, accessibility: true, inputMonitoring: false) == nil
              && R.reason(inputMonitoringAtLaunch: true, accessibility: false, inputMonitoring: true) == nil,
              "no Quit & Reopen when both are allowed as they were at launch, or while one is still off")
        // Coming back to DayDream to drag a card is the normal path: a permission still off after a visit to System
        // Settings is not a reason to reopen (the quiet "Already turned on in System Settings?" has the link).
        check(R.reason(inputMonitoringAtLaunch: false, accessibility: true, inputMonitoring: false) == nil
              && R.reason(inputMonitoringAtLaunch: true, accessibility: false, inputMonitoring: false) == nil,
              "a permission still off after a visit to System Settings: no Quit & Reopen step")
        check(R.inputMonitoringTurnedOn.text == "Input Monitoring starts working after DayDream reopens.", "the relaunch line")
    }

    /// The real helper script with `echo` standing in for `open`: it waits for a live pid to end, then
    /// "opens" the path it was given. Nothing is opened.
    static func helperScript() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dd-relaunch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("opened.txt")
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["1.2"]
        try? sleeper.run()
        let script = echoScript()
        check(script != PermissionRequests.relaunchScript, "echo stands in for open in the helper test")
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: PermissionRequests.relaunchShell)
        var args = PermissionRequests.relaunchArguments(app: URL(fileURLWithPath: "/Applications/Day Dream's.app"), pid: sleeper.processIdentifier)
        args[1] = script; args.append(out.path)
        helper.arguments = args
        let start = Date()
        try? helper.run()
        Thread.sleep(forTimeInterval: 0.5)
        check(sleeper.isRunning && !FileManager.default.fileExists(atPath: out.path), "the helper waits while DayDream is still running")
        helper.waitUntilExit()
        let opened = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
        check(helper.terminationStatus == 0 && !sleeper.isRunning && Date().timeIntervalSince(start) >= 1.0
              && opened == "/Applications/Day Dream's.app\n", "after DayDream quits, the helper opens the same app: \(opened.debugDescription)")
    }

    /// rc-018 RC3 (A6): the helper with a short wait (3 tries) and echo for open: a DayDream that didn't quit is never
    /// opened over; the background helper "opens" with -g. Only this check's own /bin/sleep is waited on and ended.
    static func helperStillRunning() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dd-relaunch-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func run(_ script: String, pid: pid_t, _ name: String) -> (Int32, String) {
            let out = dir.appendingPathComponent(name)
            let short = script.replacingOccurrences(of: "$i -lt 150", with: "$i -lt 3")
                .replacingOccurrences(of: "exec /usr/bin/open -g \"$2\"", with: "/bin/echo -g \"$2\" > \"$3\"")
                .replacingOccurrences(of: "exec /usr/bin/open \"$2\"", with: "/bin/echo \"$2\" > \"$3\"")
            guard !short.contains("/usr/bin/open") else { return (-1, "open still in the script") }
            let helper = Process()
            helper.executableURL = URL(fileURLWithPath: PermissionRequests.relaunchShell)
            helper.arguments = ["-c", short, "daydream-relaunch", String(pid), "/Applications/DayDream.app", out.path]
            try? helper.run(); helper.waitUntilExit()
            return (helper.terminationStatus, (try? String(contentsOf: out, encoding: .utf8)) ?? "")
        }
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep"); sleeper.arguments = ["10"]
        try? sleeper.run()
        let alive = run(PermissionRequests.relaunchScript, pid: sleeper.processIdentifier, "alive.txt")
        check(alive.0 == 0 && alive.1.isEmpty && sleeper.isRunning, "A6 DayDream still running after the wait: the helper opens nothing: \(alive)")
        sleeper.terminate(); sleeper.waitUntilExit()
        let gone = run(PermissionRequests.backgroundRelaunchScript, pid: sleeper.processIdentifier, "gone.txt")
        check(gone.0 == 0 && gone.1 == "-g /Applications/DayDream.app\n", "A6 the background helper opens the app with -g once DayDream quit: \(gone)")
    }

    static func echoScript() -> String {
        PermissionRequests.relaunchScript.replacingOccurrences(of: "exec /usr/bin/open \"$2\"", with: "/bin/echo \"$2\" > \"$3\"")
    }

    // MARK: D. Quitting with a sheet attached (child copies of this check)

    static func quitWithSheet() {
        func run(_ variant: String, extra: String? = nil) -> (code: Int32, output: String) {
            let child = Process()
            child.executableURL = Bundle.main.executableURL
            child.arguments = ["--quit-child", variant] + (extra.map { [$0] } ?? [])
            let pipe = Pipe(); child.standardOutput = pipe; child.standardError = pipe
            try? child.run()
            let deadline = Date().addingTimeInterval(15)
            while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
            if child.isRunning { child.terminate(); child.waitUntilExit() }
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (child.terminationStatus, output)
        }
        let plain = run("plain")
        check(plain.code == 3 && plain.output.contains("attached=true") && !plain.output.contains("WILL TERMINATE"),
              "control: the bare NSApp.terminate does not quit while a sheet is attached (why AppQuit exists): \(plain.code) \(plain.output)")
        for variant in ["appkit", "nested", "swiftui"] {
            let result = run(variant)
            check(result.code == 0 && result.output.contains("attached=true") && result.output.contains("WILL TERMINATE"),
                  "AppQuit quits with a \(variant) sheet attached: \(result.code) \(result.output)")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dd-reopen-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let out = dir.appendingPathComponent("opened.txt")
        let flow = run("reopen", extra: out.path)
        var opened = ""
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            opened = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
            if !opened.isEmpty { break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        check(flow.code == 0 && flow.output.contains("WILL TERMINATE") && opened == "/Applications/DayDream.app\n",
              "Quit & Reopen with the Settings sheet open: DayDream quits, then the helper opens it again: \(flow.code) \(flow.output) \(opened.debugDescription)")
    }

    final class ChildDelegate: NSObject, NSApplicationDelegate {
        func applicationWillTerminate(_ n: Notification) { print("WILL TERMINATE"); fflush(stdout) }
    }

    struct SheetHost: View {
        @State var shown = true
        var body: some View {
            Text("window").frame(width: 400, height: 300)
                .sheet(isPresented: $shown) { Text("sheet").frame(width: 300, height: 200) }
        }
    }

    /// A child copy: a window offscreen with a sheet, then one quit. Exit 0 = quit; exit 3 = still running.
    static func quitChild(_ variant: String, extra: String?) -> Never {
        let app = NSApplication.shared
        let delegate = ChildDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        let window = OffscreenWindow(contentRect: NSRect(x: -3000, y: -3000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.orderFrontRegardless()
        if variant == "swiftui" {
            window.contentView = NSHostingView(rootView: SheetHost())
        } else {
            let sheet = OffscreenWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
            window.beginSheet(sheet) { _ in }
            if variant == "nested" {
                let alert = OffscreenWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { sheet.beginSheet(alert) { _ in } }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            print("attached=\(window.attachedSheet != nil)"); fflush(stdout)
            switch variant {
            case "plain":
                app.terminate(nil)
            case "reopen":
                let env = PermissionRequestEnvironment(
                    open: { _ in false },
                    relaunch: { bundle, pid in
                        let helper = Process()
                        helper.executableURL = URL(fileURLWithPath: PermissionRequests.relaunchShell)
                        var args = PermissionRequests.relaunchArguments(app: bundle, pid: pid)
                        args[1] = echoScript(); args.append(extra ?? "/dev/null")
                        helper.arguments = args
                        do { try helper.run(); return true } catch { return false }
                    },
                    terminate: { AppQuit.quit() },
                    bundleURL: URL(fileURLWithPath: "/Applications/DayDream.app"),
                    pid: ProcessInfo.processInfo.processIdentifier)
                PermissionRequests.actions(env, location: .applications).quitAndReopen?()
            default:
                AppQuit.terminate(app)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { print("STILL RUNNING"); fflush(stdout); exit(3) }
        app.run()
        exit(4)
    }

    // MARK: A, F. Sources

    static func sources() {
        let fm = FileManager.default
        var users: [String] = []
        let banned = ["AXIsProcessTrustedWithOptions", "CGRequestListenEventAccess", "kAXTrustedCheckOptionPrompt", "CGRequestPostEventAccess"]
        for case let path as String in fm.enumerator(atPath: "Sources")! where path.hasSuffix(".swift") {
            let text = (try? String(contentsOfFile: "Sources/" + path, encoding: .utf8)) ?? ""
            if banned.contains(where: text.contains) { users.append(path) }
        }
        check(users.isEmpty, "no source calls a permission request API (DayDream never asks macOS; each card opens System Settings): \(users)")

        let setup = try! String(contentsOfFile: "Sources/MemoryUI/PermissionSetup.swift", encoding: .utf8)
        check(!setup.contains("Allow…") && !setup.contains("requestAccessibility") && !setup.contains("requestInputMonitoring")
              && !setup.contains("notePrompted"), "the page has no Allow button and nothing that asks macOS")
        check(setup.contains("Button { open(permission) } label: { OpenSystemSettingsLabel() }") && setup.contains("Text(\"Open System Settings\")")
              && setup.contains("Self.openPane(permission.settingsURL)")
              && setup.contains("nonisolated(unsafe) public static var openPane: (URL) -> Bool = { NSWorkspace.shared.open($0) }"),
              "a missing card's button opens its own System Settings pane")
        // rel-018 (owner's Mac mini 10/8): SwiftUI's onDrag copied the whole app into ~/Library/Caches/com.apple.SwiftUI.Drag-*
        // on every drag and System Settings registered the copy. The card's drag is AppKit's, of the URL itself.
        check(!setup.contains(".onDrag") && !setup.contains("NSItemProvider") && setup.contains("PermissionCardDrag.shared.begin(appURL: appURL, enabled: draggable")
              && setup.contains("let draggable = enabled && moveWarning == nil"), "each card drags DayDream into the System Settings list")
        check(setup.contains("@Environment(\\.daydreamPermissionRequests) private var requests"), "the actions come from the environment")
        check(setup.contains(".onReceive(timer) { _ in refresh() }") && setup.contains("Timer.publish(every: 2")
              && setup.contains("NSApplication.didBecomeActiveNotification"), "status stays live (every 2 seconds and on coming back)")
        for gone in ["Check Again", "Checked just now", "Checked ", "How DayDream uses them", "DayDream needs", "needs two permissions"] {
            check(!setup.contains(gone), "the page no longer says \(gone.debugDescription)")
        }
        check(setup.contains("Button(PermissionRequestActions.quitAndReopenTitle, action: quitAndReopen)")
              && setup.contains("if let relaunch, let quitAndReopen = requests?.quitAndReopen {")
              && setup.contains("if showsRelaunchRow { relaunchRow(relaunch, quitAndReopen) }"),
              "Quit & Reopen is a button, shown only with a relaunch reason (setup draws it as its main button instead)")
        check(!setup.contains("sentToSettings") && !setup.contains("returnedFromSystemSettings") && !setup.contains("stillOff"),
              "opening System Settings is not a reason to offer Quit & Reopen")
        check(setup.contains("public static let dragHint = \"Drag the card into the list, then turn DayDream on.\"")
              && !setup.contains("Image(systemName: \"line.3.horizontal\")")
              && setup.contains(".gesture(DragGesture(minimumDistance: 3).onChanged { _ in")
              && setup.contains(".pointerStyle(draggable && !isAllowed && read && known(permission) ? .grabIdle : nil)"),
              "dragging is the step: the hint says so; the whole card drags with an open hand, no grip glyph")
        check(setup.contains("if !sideBySide, let line = PermissionRowHelp.rowLine")
              && setup.contains("} else if !missing.isEmpty && !sideBySide { recovery }"),
              "setup (side by side) draws no row line and no \"Already turned on\" disclosure; Settings and the permissions window keep them")
        // fix/setup-tweaks (owner, 9/28): the hint shows only after a card's pane opened and that permission is still
        // missing, in room the page keeps (it never moves the page).
        // rel-018: setup's Input Monitoring card says the step itself while its pane is open beside setup, so the longer
        // hint is held back for it (`longHintShows`); everywhere else it is the hint as before.
        check(setup.contains("dragHint.paneOpened(permission.rawValue, at: Date())") && setup.contains(".opacity(longHintShows ? 1 : 0)")
              && setup.contains("dragHint.shows && !(guideLine && dragHint.waiting == [guidePermission.rawValue])"),
              "the drag hint waits for a pane to open, in room kept for it")
        // The cards stay beside System Settings: the window floats after a pane opens, and goes back once both are
        // allowed or the page closes.
        check(setup.contains("if Self.openPane(permission.settingsURL) {") && setup.contains("window.set(floating: true)")
              && setup.contains("if floating && accessibility && inputMonitoring { floating = false; window.set(floating: false) }")
              && setup.contains(".onDisappear { floating = false; window.set(floating: false);"),  // rel-018: setup also ends its helper there
              "the permission window floats above System Settings only while a permission is missing")

        let app = try! String(contentsOfFile: "Sources/MacMemApp/MacMemApp.swift", encoding: .utf8)
        // perm-1004: the onboarding and permissions windows get them through PermissionRequestsHost, which observes the
        // model so a pane request or the restart line reaches an open page.
        check(app.components(separatedBy: ".environment(\\.daydreamPermissionRequests,").count == 3
              // permflash-015 (c16a6d5): the permissions window opens on the app's settled snapshot.
              && app.contains("DaydreamPermissionSettings(enabled:model.development == nil,known:model.permissionSnapshot,allowedBefore:model.permissionsAllowedBefore)")
              // rc-018 RC3: inside PermissionsWindowFocus (the permissions window's own hand-back).
              && app.contains("PermissionRequestsHost(model:model) {\n                        DaydreamPermissionSettings(enabled:model.development == nil,")
              && app.contains("PermissionRequestsHost(model:model) {DaydreamOnboarding(model:model)}"),
              "Settings, onboarding and the permissions window all get the actions")
        check(app.contains("guard development == nil else {return nil}\n        var actions=PermissionRequests.actions(.live,location:launchLocation,inputMonitoringAtLaunch:permissionsAtLaunch?.inputMonitoring)"),
              "the Development Trial gets no actions; the app passes its launch read")
        // gold/int final review (G33), gold r2 (V1): an Input Monitoring off read at launch that reads on again before a
        // read confirms it was a moment's "not allowed", as a later off read counts only once confirmed. A read decides,
        // not a deadline: the launch read's own confirm read comes `confirmAfter` later (permission-blip G runs it).
        check(app.contains("if permissionsAtLaunch == nil {\n            permissionsAtLaunch=read\n")
              && app.contains("if on {permissionsAtLaunch?.inputMonitoring=true;launchReadUnconfirmedSince=nil}")
              && app.contains("MainActor.assumeIsolated { self?.refreshCaptureStatus() }"),
              "the launch read is the first read, kept (an off read on again before a read confirms it was a moment's \"not allowed\")")
        check(!banned.contains(where: app.contains), "the app model only reads permissions")

        // Every quit in the shipped app goes through AppQuit (AppKit won't quit under a sheet otherwise).
        let requests = try! String(contentsOfFile: "Sources/MacMemApp/PermissionRequests.swift", encoding: .utf8)
        check(requests.contains("terminate: { AppQuit.quit() },") && requests.contains("endSheets(app)\n            app.terminate(nil)"),
              "Quit & Reopen quits through AppQuit, which ends the sheets right before each quit")
        check(app.contains("AppQuit.willQuit = { [weak self] in self?.settingsPresented=false;self?.willQuit() }")
              && app.contains("Button(LaunchLocation.quitTitle) { AppQuit.terminate() }"), "the model closes Settings on quit (rc-018 RC3: and saves an open setup's place); the download alert quits through AppQuit")
        let menu = try! String(contentsOfFile: "Sources/MacMemApp/MenuBarContent.swift", encoding: .utf8)
        let uninstall = try! String(contentsOfFile: "Sources/MacMemApp/UninstallService.swift", encoding: .utf8)
        check(menu.components(separatedBy: "{ AppQuit.quit() }").count == 3 && !menu.contains("NSApp.terminate")
              && uninstall.contains("func quit() { AppQuit.terminate() }") && !uninstall.contains("NSApp.terminate"),
              "the menu bar's Quit and the uninstaller quit through AppQuit")
    }

    // MARK: C. The laid-out page: Quit & Reopen appears only when needed, and a click runs the injected launcher

    struct RootFrameKey: PreferenceKey {
        static var defaultValue: CGRect { .zero }
        static func reduce(value: inout CGRect, nextValue: () -> CGRect) { let next = nextValue(); if next != .zero { value = next } }
    }
    static var elements: [String: CGRect] = [:]
    static var rootFrame = CGRect.zero
    static let window: NSWindow = {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        let w = OffscreenWindow(contentRect: NSRect(x: -4000, y: -4000, width: 640, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        w.orderFrontRegardless()
        return w
    }()
    static func pump(_ s: Double = 0.15) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }

    /// A mouse down and up at the center of a reported element (as dd-settings-status-checks clicks).
    static func click(_ view: NSView, _ key: String) -> Bool {
        guard let frame = elements[key] else { return false }
        let point = CGPoint(x: frame.midX - rootFrame.minX, y: frame.midY - rootFrame.minY)
        let inView = view.isFlipped ? NSPoint(x: point.x, y: point.y) : NSPoint(x: point.x, y: view.bounds.height - point.y)
        let p = view.convert(inView, to: nil)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: p, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else { return false }
        NSApp.postEvent(up, atStart: false)
        window.sendEvent(down)
        if let queued = NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) { window.sendEvent(queued) }
        pump(0.05)
        return true
    }

    static func pageButtons() async throws {
        func host(_ r: Recorder, atLaunch: Bool?, accessibility: Bool, input: Bool, relaunchRow: Bool = true, bundle: String = "/Applications/DayDream.app") -> NSView {
            elements = [:]; rootFrame = .zero
            let actions = PermissionRequests.actions(r.env(bundle: bundle), location: .applications, inputMonitoringAtLaunch: atLaunch)
            let view = PermissionGrantView(appURL: URL(fileURLWithPath: "/Applications/DayDream.app"), readAccessibility: { accessibility },
                                           readInputMonitoring: { input }, embedded: true, style: .settings, showsRelaunchRow: relaunchRow)
                .environment(\.daydreamPermissionRequests, actions).padding(20).frame(width: 600, height: 600, alignment: .top)
                .background(GeometryReader { Color.clear.preference(key: RootFrameKey.self, value: $0.frame(in: .global)) })
                .onPreferenceChange(PermissionPageElements.self) { elements = $0 }
                .onPreferenceChange(RootFrameKey.self) { rootFrame = $0 }
            let h = NSHostingView(rootView: view)
            window.setContentSize(NSSize(width: 600, height: 600))
            window.contentView = h
            h.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
            pump(); h.layoutSubtreeIfNeeded(); pump(0.05)
            return h
        }
        defer { window.contentView = nil; window.orderOut(nil) }
        var r = Recorder()
        _ = host(r, atLaunch: true, accessibility: true, input: true)
        check(!NSScreen.screens.contains { $0.frame.intersects(window.frame) },
              "the check's window stays off every screen once shown (an OffscreenWindow): \(window.frame)")
        check(elements["card.accessibility"] != nil && elements["card.inputMonitoring"] != nil && elements["quitAndReopen"] == nil
              && elements["open.accessibility"] == nil && elements["open.inputMonitoring"] == nil,
              "both allowed as at launch: two cards, no Open System Settings, no Quit & Reopen: \(elements.keys.sorted())")
        _ = host(r, atLaunch: false, accessibility: true, input: false)
        check(elements["open.inputMonitoring"] != nil && elements["open.accessibility"] == nil && elements["quitAndReopen"] == nil
              && elements["recovery"] != nil,
              "Input Monitoring missing: its card has Open System Settings, the recovery steps, and no Quit & Reopen before a visit: \(elements.keys.sorted())")
        if let open = elements["open.inputMonitoring"], let card = elements["card.inputMonitoring"] {
            check(card.contains(open), "the button sits on its own card")
        }
        r = Recorder()
        var h = host(r, atLaunch: false, accessibility: true, input: true)
        check(elements["quitAndReopen"] != nil, "Input Monitoring turned on since launch: the page offers Quit & Reopen: \(elements.keys.sorted())")
        check(click(h, "quitAndReopen") && r.calls == ["relaunch /Applications/DayDream.app 4242", "terminate"],
              "a click on Quit & Reopen runs the launcher, then the quit: \(r.calls)")
        r = Recorder()
        _ = host(r, atLaunch: false, accessibility: true, input: true, relaunchRow: false)
        check(elements["quitAndReopen"] == nil && elements["recovery"] == nil && r.calls.isEmpty,
              "setup (showsRelaunchRow: false) draws no Quit & Reopen row: its main button is Quit & Reopen")
        r = Recorder()
        h = host(r, atLaunch: true, accessibility: false, input: true)
        check(elements["quitAndReopen"] == nil && elements["open.accessibility"] != nil && elements["recovery"] != nil,
              "Accessibility still off (for example after a visit to System Settings): Open System Settings and the quiet recovery steps, no blue Quit & Reopen")
        r = Recorder()
        h = host(r, atLaunch: false, accessibility: true, input: true, bundle: "/Volumes/Work/build/debug")
        check(elements["quitAndReopen"] == nil && r.calls.isEmpty, "a development binary never shows Quit & Reopen")
        _ = host(r, atLaunch: true, accessibility: false, input: true, bundle: "/Volumes/Work/build/debug")
        check(elements["quitAndReopen"] == nil && elements["recovery"] != nil, "…and shows the recovery steps instead")
        // The recovery steps' first step is a Quit & Reopen button where DayDream can reopen itself (open disclosure).
        r = Recorder()
        elements = [:]; rootFrame = .zero
        let open = NSHostingView(rootView: PermissionGrantView(appURL: URL(fileURLWithPath: "/Applications/DayDream.app"), readAccessibility: { false },
                                                           readInputMonitoring: { true }, embedded: true, style: .settings, recoveryExpandedInitially: true)
            .environment(\.daydreamPermissionRequests, PermissionRequests.actions(r.env(), location: .applications, inputMonitoringAtLaunch: true))
            .padding(20).frame(width: 600, height: 600, alignment: .top)
            .background(GeometryReader { Color.clear.preference(key: RootFrameKey.self, value: $0.frame(in: .global)) })
            .onPreferenceChange(PermissionPageElements.self) { elements = $0 }
            .onPreferenceChange(RootFrameKey.self) { rootFrame = $0 })
        window.contentView = open
        open.frame = NSRect(x: 0, y: 0, width: 600, height: 600)
        pump(); open.layoutSubtreeIfNeeded(); pump(0.05)
        check(elements["quitAndReopen"] == nil && elements["recovery.quitAndReopen"] != nil, "the open recovery steps offer Quit & Reopen: \(elements.keys.sorted())")
        check(click(open, "recovery.quitAndReopen") && r.calls == ["relaunch /Applications/DayDream.app 4242", "terminate"],
              "a click on it runs the launcher, then the quit: \(r.calls)")
        _ = h
    }

    // MARK: G. Renders

    static func renders() async throws {
        guard let out = ProcessInfo.processInfo.environment["DD_CHECK_OUT"] else { check(false, "DD_CHECK_OUT is set"); return }
        let dir = URL(fileURLWithPath: out).appendingPathComponent("recording-permission-renders")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let window = OffscreenWindow(contentRect: NSRect(x: -4000, y: -4000, width: 660, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
        defer { window.contentView = nil; window.orderOut(nil) }
        let appURL = URL(fileURLWithPath: "/Applications/DayDream.app")
        var count = 0
        // state 0: both missing, 1: Input Monitoring missing, 2: both allowed, 3: Input Monitoring turned on since launch.
        for (name, location) in [("applications", LaunchLocation.applications), ("download", .diskImage)] {
            for style in [PermissionGrantStyle.cards, .settings] { for state in 0...3 { for dark in [false, true] {
                let r = Recorder()
                let actions = PermissionRequests.actions(r.env(), location: location, inputMonitoringAtLaunch: state == 3 ? false : nil)
                let view = PermissionGrantView(appURL: appURL, readAccessibility: { state >= 1 }, readInputMonitoring: { state >= 2 },
                                               embedded: style == .cards, style: style)
                    .environment(\.daydreamPermissionRequests, actions)
                    .padding(20).frame(width: style == .settings ? 560 : 660)
                let host = NSHostingView(rootView: view)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = host
                let size = host.fittingSize
                host.frame = NSRect(origin: .zero, size: size)
                // The run loop, not Task.sleep: awaiting here let the async main's run loop return and the process
                // exit 0 before the first render (every render check and the final count were skipped).
                pump(0.12)
                host.layoutSubtreeIfNeeded()
                check(size.width > 0 && size.height > 0 && r.calls.isEmpty, "renders without asking macOS: \(name) \(style) \(state) \(dark)")
                guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { check(false, "bitmap"); return }
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let file = "\(name)-\(style == .cards ? "cards" : "settings")-\(state)-\(dark ? "dark" : "light").png"
                try bitmap.representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(file))
                count += 1
            }}}
        }
        check(count == 32, "32 renders written to \(dir.path)")
    }
}
