import AppKit
import MemoryCore
import MemoryUI

// The permission page's actions (SPEC 6.3 R2). DayDream never asks macOS for a permission: each card on the page
// opens its own System Settings pane and drags DayDream into that pane's list (PermissionGrantView). `Quit & Reopen`
// relaunches DayDream when macOS needs it to see a new permission. The model and every surface only read
// permissions (AXIsProcessTrusted, CGPreflightListenEventAccess); scripts/recording-permission-checks.swift pins
// that no source calls a request API.

/// What the actions ask the system. The checks substitute recorders; `.live` is the app's.
struct PermissionRequestEnvironment {
    /// Opens a URL (the Applications folder). Returns false when nothing opened.
    var open: (URL) -> Bool
    /// Starts a helper that waits for this process to end, then opens the app again. Returns false when
    /// it couldn't start (then DayDream stays open).
    var relaunch: (_ app: URL, _ pid: pid_t) -> Bool
    /// rc-018 RC3 (A6): the same helper for a restart nobody asked to see ("keys not arriving" while recording): it opens
    /// the app with `open -g`, in the background, and the next launch shows no window. nil: `relaunch`.
    var relaunchInBackground: ((_ app: URL, _ pid: pid_t) -> Bool)? = nil
    /// Quits DayDream (`AppQuit.terminate`: it closes an open Settings sheet first, which AppKit needs).
    var terminate: () -> Void
    var bundleURL: URL
    var pid: pid_t

    static var live: PermissionRequestEnvironment {
        PermissionRequestEnvironment(
            open: { NSWorkspace.shared.open($0) },
            relaunch: { app, pid in PermissionRequests.startHelper(app: app, pid: pid, background: false) },
            relaunchInBackground: { app, pid in PermissionRequests.startHelper(app: app, pid: pid, background: true) },
            terminate: { AppQuit.quit() },
            bundleURL: Bundle.main.bundleURL,
            pid: ProcessInfo.processInfo.processIdentifier)
    }
}

enum PermissionRequests {
    static let relaunchShell = "/bin/sh"
    /// Waits (up to about 30 seconds) for this DayDream to quit, so the new one can take the recorder lock,
    /// then opens the same app bundle. The pid and path are arguments, never pasted into the script.
    /// rc-018 RC3 (A6): a DayDream still running after the wait (its quit was refused) is never opened over: the helper
    /// ends without opening anything.
    static let relaunchScript = "i=0; while /bin/kill -0 \"$1\" 2>/dev/null && [ $i -lt 150 ]; do /bin/sleep 0.2; i=$((i+1)); done; /bin/kill -0 \"$1\" 2>/dev/null && exit 0; exec /usr/bin/open \"$2\""
    /// The same, opening the app in the background (`open -g`): a restart nobody asked to see.
    static let backgroundRelaunchScript = relaunchScript.replacingOccurrences(of: "exec /usr/bin/open \"$2\"", with: "exec /usr/bin/open -g \"$2\"")

    static func relaunchArguments(app: URL, pid: pid_t, background: Bool = false) -> [String] {
        ["-c", background ? backgroundRelaunchScript : relaunchScript, "daydream-relaunch", String(pid), app.path]
    }

    /// The helper started last (the app's own restart); `cancelHelper` ends it when DayDream's quit didn't happen.
    nonisolated(unsafe) private static var helper: Process?
    /// Starts the relaunch helper; false when it couldn't start.
    static func startHelper(app: URL, pid: pid_t, background: Bool) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: relaunchShell)
        process.arguments = relaunchArguments(app: app, pid: pid, background: background)
        do { try process.run() } catch { return false }
        helper = process
        // rel-018: the reopened DayDream is not the person opening it (UsageLaunch, app_opened).
        UsageLaunch.markSelfRelaunch(.standard)
        return true
    }
    /// A6: DayDream asked to quit for its restart and is still running: the helper waiting for it goes, so nothing opens
    /// DayDream again later out of the blue.
    static func cancelHelper() {
        if let helper, helper.isRunning { helper.terminate() }
        helper = nil
    }

    /// A6: the restart itself, for the app's own callers: starts the helper, then quits. false when the helper couldn't
    /// start (DayDream stays open and nothing quits) or DayDream can't reopen itself.
    static func quitAndReopen(_ env: PermissionRequestEnvironment, background: Bool = false) -> Bool {
        guard canRelaunch(env.bundleURL) else { return false }
        let start = background ? (env.relaunchInBackground ?? env.relaunch) : env.relaunch
        guard start(env.bundleURL, env.pid) else { return false }
        env.terminate()
        return true
    }

    /// Only a real app bundle can be reopened; a development binary gets no Quit & Reopen button.
    static func canRelaunch(_ app: URL) -> Bool { app.isFileURL && app.pathExtension == "app" }

    /// The page's actions (`\.daydreamPermissionRequests`). `location`: where DayDream runs; from the download
    /// window the cards are replaced by the move warning. `inputMonitoringAtLaunch`: the model's first read.
    static func actions(_ env: PermissionRequestEnvironment, location: LaunchLocation,
                        inputMonitoringAtLaunch: Bool? = nil) -> PermissionRequestActions {
        let blocked = location.blocksRecording
        return PermissionRequestActions(
            quitAndReopen: canRelaunch(env.bundleURL) ? { _ = quitAndReopen(env) } : nil,
            inputMonitoringAtLaunch: inputMonitoringAtLaunch,
            moveWarning: blocked ? LaunchLocation.warning : nil,
            moveDetail: blocked ? LaunchLocation.detail : nil,
            openApplications: { _ = env.open(LaunchLocation.applicationsFolder) })
    }
}

/// Quitting DayDream from anywhere, including while the Settings sheet is open. AppKit refuses
/// `NSApp.terminate` while a window has a sheet attached (it just returns, before it asks the app delegate), so the
/// sheets are ended first and the quit runs on the next turn of the run loop. A SwiftUI sheet whose state still says
/// "shown" can come back in between, so each attempt ends the sheets again right before it quits, and a refused
/// attempt tries again.
/// Every way DayDream is asked to quit comes through here:
/// - its own buttons: Quit & Reopen, the menu bar's Quit, the download-window alert's Quit, the uninstaller's quit;
/// - DayDream ▸ Quit DayDream ⌘Q (AppCommands replaces AppKit's own Quit item, which does nothing under a sheet);
/// - the quit Apple event (`installQuitEventHandler`): the Dock's Quit, log out, restart and shut down, and Sparkle's
///   installer after Install and Relaunch. AppKit's own handler refuses it under a sheet and answers "cancelled",
///   which makes macOS say DayDream stopped the restart, and leaves an update waiting for a quit that never comes.
@MainActor enum AppQuit {
    /// Runs before the sheets are ended: the app model closes its Settings sheet state here.
    static var willQuit: () -> Void = {}

    /// For the default closures (buttons and menu items, which run on the main thread).
    nonisolated static func quit() {
        if Thread.isMainThread { MainActor.assumeIsolated { terminate() } }
        else { DispatchQueue.main.async { terminate() } }
    }

    /// `app`: the checks pass their own application; nil means NSApp.
    static func terminate(_ application: NSApplication? = nil) {
        guard let app = application ?? NSApp else { return }
        prepare(app)
        attempt(app, left: 10)
    }

    /// What every quit does first, and what Sparkle's relaunch does before its installer asks DayDream to quit: the
    /// model closes its Settings sheet state, a modal session ends, and every attached sheet is ended.
    static func prepare(_ application: NSApplication? = nil) {
        guard let app = application ?? NSApp else { return }
        willQuit()
        if app.modalWindow != nil { app.abortModal() }
        endSheets(app)
    }

    /// The quit Apple event, answered at once: sheets first, then AppKit's terminate (which doesn't return when it
    /// quits). If AppKit still refused (a sheet that came straight back), the retries of `terminate` run, and the
    /// reply stays "no error": the quit is on its way.
    static func quitForEvent(_ application: NSApplication? = nil) {
        guard let app = application ?? NSApp else { return }
        prepare(app)
        app.terminate(nil)
        attempt(app, left: 10)
    }

    /// Answers the quit Apple event through `quitForEvent`. AppKit installs its own handler as it finishes launching
    /// and would replace one installed before that, so this installs it once launching has finished (at once when it
    /// already has). Safe to call more than once.
    static func installQuitEventHandler() {
        guard !quitEventsInstalled else { return }
        quitEventsInstalled = true
        if NSRunningApplication.current.isFinishedLaunching { AppQuitEvents.install(); return }
        launchObserver = NotificationCenter.default.addObserver(forName: NSApplication.didFinishLaunchingNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                if let observer = launchObserver { NotificationCenter.default.removeObserver(observer) }
                launchObserver = nil
                AppQuitEvents.install()
                // Again on the next turn, after anything else that runs as launching finishes.
                DispatchQueue.main.async { AppQuitEvents.install() }
            }
        }
    }
    private static var quitEventsInstalled = false
    private static var launchObserver: NSObjectProtocol?

    /// One quit: end any sheet that came back, then terminate. If AppKit still refused, try again shortly.
    private static func attempt(_ app: NSApplication, left: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + (left == 10 ? 0 : 0.2)) {
            if app.modalWindow != nil { app.abortModal() }
            endSheets(app)
            app.terminate(nil)
            if left > 1 { attempt(app, left: left - 1) }
        }
    }

    /// Ends every attached sheet, innermost first (an alert on the Settings sheet, then the sheet). Bounded:
    /// a sheet that won't end never loops forever.
    static func endSheets(_ app: NSApplication) {
        for _ in 0..<8 {
            let attached = app.windows.compactMap { window in window.attachedSheet.map { (window, $0) } }
            if attached.isEmpty { return }
            for (window, sheet) in attached where sheet.attachedSheet == nil {
                window.endSheet(sheet)
                sheet.orderOut(nil)
            }
        }
    }
}

/// The quit Apple event's target: `NSAppleEventManager` calls an Objective-C selector on the main thread.
final class AppQuitEvents: NSObject {
    static let shared = AppQuitEvents()
    static func install() {
        NSAppleEventManager.shared().setEventHandler(shared, andSelector: #selector(handle(_:withReply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }
    @objc func handle(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        if Thread.isMainThread { MainActor.assumeIsolated { AppQuit.quitForEvent() } }
        else { DispatchQueue.main.async { AppQuit.quitForEvent() } }
    }
}
