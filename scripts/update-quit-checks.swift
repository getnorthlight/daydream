// DD-RECIPE: APP
// Updates and quitting (golden test 5, stream updates-release: G9, G40, G53, G76). Nothing here checks for,
// downloads or installs an update: no Sparkle updater is started, and the Sparkle calls are the delegate calls
// Sparkle makes, made by this check. The only processes that quit are child copies of this check (accessory
// policy, one offscreen window). Preferences are in memory (UQMemoryDefaults): no check writes a preferences
// file. Nothing records.
//   A. Quitting while Settings is open (G40). A child copy is a SwiftUI app with DayDream's menus
//      (DaydreamCommands) and the quit event handler installed the way AppCommands installs it, and a window with a
//      Settings-style SwiftUI sheet. Controls: the bare NSApp.terminate, and AppKit's own quit event handler
//      (answering "cancelled", -128, which macOS reports as DayDream stopping a restart), leave it running.
//      DayDream ▸ Quit DayDream (the item, and ⌘Q through the main menu) and the quit Apple event (plain, restart,
//      log out, and a sheet whose own state still says shown) quit it.
//   B. Install and Relaunch (G9). In a child: Sparkle's install and relaunch calls close the sheet, and the
//      installer's quit event then quits it (with AppKit's own handler, and with DayDream's); recording is still
//      on at the quit. In this process: Sparkle's install call changes nothing; the relaunch leaves the marker only
//      when recording is on; the marker goes when the install stops or is cancelled, or when DayDream is still
//      running after the grace period; an earlier relaunch's timer never cuts a later one short.
//   C. The status line (G53, G76). A scheduled check that can't read the update page (a feed that isn't
//      published: 1002 wrapping a download error) or can't reach it (offline) leaves the line alone, in either
//      callback order. Check Now answers with one line, "Checking…" never stays, and the next good check replaces
//      a failure. A cancelled install (4007, 4008) keeps "DayDream N is available."; an install that failed, or a
//      copy that must move to Applications, says so even unasked.
//   D. Sources: nothing pauses recording for an update before the quit, downloads follow the one switch at start,
//      and the quit event handler and ⌘Q are wired through AppQuit.
//   E. Quiet updates (updates-1003): a downloaded update waits (Restart to Update), Sparkle's install-now block runs
//      only from that action, a scheduled update Sparkle would show in a window is offered quietly instead, and the
//      menu bar menu shows the one row right above Quit only while an update waits.
import AppKit
import SwiftUI
import Sparkle
import MemoryCore
import MemoryUI

@MainActor @main enum UpdateQuitChecks {
    static var passes = 0
    static var failures = 0
    static func check(_ ok: Bool, _ name: String) {
        if ok { passes += 1; print("PASS " + name) }
        else { failures += 1; FileHandle.standardError.write(Data("FAIL: \(name)\n".utf8)) }
        fflush(stdout)
    }

    static func main() {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--quit-child"), i + 1 < args.count {
            UQChild.variant = args[i + 1]
            UQChildApp.main()
            exit(4)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
            FileHandle.standardError.write(Data("FAIL: update-quit-checks watchdog expired after 300s\n".utf8)); exit(2)
        }
        quitting()
        relaunchMarker()
        statusLine()
        sources()
        quietUpdates()
        if failures > 0 {
            FileHandle.standardError.write(Data("FAIL: \(failures) update-quit checks failed (\(passes) passed)\n".utf8)); exit(1)
        }
        print("PASS all \(passes) update-quit checks")
    }

    /// Runs the main run loop (and so the main queue) for a while.
    static func pump(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    /// A Sparkle updater for the delegate calls: never started, so it never checks, downloads or installs.
    static func sparkle(_ delegate: SPUUpdaterDelegate) -> (SPUUpdater, SUAppcastItem) {
        let driver = SPUStandardUserDriver(hostBundle: .main, delegate: nil)
        return (SPUUpdater(hostBundle: .main, applicationBundle: .main, userDriver: driver, delegate: delegate), SUAppcastItem.empty())
    }

    // MARK: A, B. Child copies that quit (or don't)

    static func child(_ variant: String) -> (code: Int32, output: String) {
        let child = Process()
        child.executableURL = Bundle.main.executableURL
        child.arguments = ["--quit-child", variant]
        let pipe = Pipe(); child.standardOutput = pipe; child.standardError = pipe
        do { try child.run() } catch { return (-1, "didn't start: \(error)") }
        let deadline = Date().addingTimeInterval(20)
        while child.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if child.isRunning { child.terminate(); child.waitUntilExit() }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (child.terminationStatus, output.replacingOccurrences(of: "\n", with: " | "))
    }

    static func quitting() {
        let bare = child("terminate-control")
        check(bare.code == 3 && bare.output.contains("attached=true") && !bare.output.contains("WILL TERMINATE"),
              "control: the bare NSApp.terminate leaves DayDream running while Settings is open: \(bare.code) \(bare.output)")
        let appkit = child("event-control")
        check(appkit.code == 3 && appkit.output.contains("attached=true") && appkit.output.contains("errn=-128") && !appkit.output.contains("WILL TERMINATE"),
              "control: AppKit's own quit event handler answers cancelled (-128) while Settings is open and DayDream stays running: \(appkit.code) \(appkit.output)")
        let quits: [(String, String)] = [
            ("menu-item", "DayDream ▸ Quit DayDream"),
            ("menu-key", "⌘Q through the main menu"),
            ("event", "the quit Apple event (the Dock's Quit, Sparkle's installer)"),
            ("event-restart", "a restart's quit event"),
            ("event-logout", "a log out's quit event"),
            ("event-unwired", "the quit event, with a sheet whose own state still says shown"),
        ]
        for (variant, what) in quits {
            let r = child(variant)
            check(r.code == 0 && r.output.contains("attached=true") && r.output.contains("WILL TERMINATE"),
                  "\(what) quits DayDream while Settings is open: \(r.code) \(r.output)")
            if variant == "menu-item" {
                check(r.output.contains("item=Quit DayDream key=q"), "the app menu's ⌘Q item is DayDream's Quit DayDream: \(r.output)")
            }
            if variant.hasPrefix("event") {
                check(!r.output.contains("errn=-128"), "\(what) is not answered cancelled: \(r.output)")
            }
        }
        for (variant, what) in [("relaunch", "AppKit's own quit handler"), ("relaunch-handler", "DayDream's quit handler")] {
            let r = child(variant)
            check(r.code == 0 && r.output.contains("attached=true")
                  && r.output.contains("relaunch: attached=false recording=true marker=true")
                  && r.output.contains("WILL TERMINATE recording=true"),
                  "Install and Relaunch with Settings open (\(what)): the sheet closes, recording is still on, the installer's quit event quits DayDream: \(r.code) \(r.output)")
        }
    }

    // MARK: B. The relaunch marker (this process)

    static func relaunchMarker() {
        guard let store = UQMemoryDefaults(inMemory: true) else { check(false, "preferences in memory"); return }
        var recording = true
        var prepared = 0
        let updates = Updates()
        updates.defaults = store
        updates.isRecording = { recording }
        updates.prepareToQuit = { prepared += 1 }
        updates.relaunchGrace = 0.4
        let (updater, item) = sparkle(updates)
        func marker() -> [String: Any]? { updates.defaults.dictionary(forKey: UpdateResume.key) }

        (updates as SPUUpdaterDelegate).updater?(updater, willInstallUpdate: item)
        check(marker() == nil && prepared == 0 && !updates.relaunchPending,
              "Sparkle's install call changes nothing: no marker and nothing closed (the quit pauses recording, not the install)")
        updates.updaterWillRelaunchApplication(updater)
        check(marker() != nil && UpdateResume.shouldResume(marker: marker(), now: Date()) && prepared == 1 && updates.relaunchPending,
              "the relaunch with recording on leaves a marker that counts, and closes the sheets before the installer's quit")
        updates.updater(updater, didAbortWithError: NSError(domain: SUSparkleErrorDomain, code: 4005))
        check(marker() == nil && !updates.relaunchPending && updates.status == UpdateText.installFailed,
              "the install stopped after the relaunch began: the marker is gone and the line says the install failed: \(updates.status)")
        updates.updaterWillRelaunchApplication(updater)
        updates.updater(updater, didFinishUpdateCycleFor: .updates, error: NSError(domain: SUSparkleErrorDomain, code: 4007))
        check(marker() == nil && !updates.relaunchPending, "a cycle that ended cancelled after the relaunch began removes the marker")

        updates.updaterWillRelaunchApplication(updater)
        pump(0.15)
        check(marker() != nil, "the marker stays while the relaunch can still happen")
        pump(0.6)
        check(marker() == nil && !updates.relaunchPending, "DayDream still running after the grace period: the relaunch didn't happen, the marker is gone")

        updates.updaterWillRelaunchApplication(updater)
        pump(0.2)
        updates.relaunchGrace = 1.5
        updates.updaterWillRelaunchApplication(updater)
        pump(0.5)
        check(marker() != nil && updates.relaunchPending, "an earlier relaunch's timer doesn't cut a later relaunch short")
        pump(1.4)
        check(marker() == nil, "the later relaunch's own timer removes it")

        recording = false
        updates.defaults.set(UpdateResume.marker(build: "1", at: Date()), forKey: UpdateResume.key)
        updates.updaterWillRelaunchApplication(updater)
        check(marker() == nil, "the relaunch with recording off leaves no marker (and removes an older one)")
        updates.relaunchEnded()
        UpdateResume.record(store, build: "7", at: Date())
        check((store.dictionary(forKey: UpdateResume.key)?["build"] as? String) == "7", "UpdateResume.record leaves the marker")
        UpdateResume.clear(store)
        check(store.dictionary(forKey: UpdateResume.key) == nil, "UpdateResume.clear removes it")
    }

    // MARK: C. The status line (this process)

    static func statusLine() {
        let updates = Updates()
        let (updater, item) = sparkle(updates)
        let feedMissing = NSError(domain: SUSparkleErrorDomain, code: 1002,
                                  userInfo: [NSUnderlyingErrorKey: NSError(domain: SUSparkleErrorDomain, code: 2001)])
        let offline = NSError(domain: SUSparkleErrorDomain, code: 1002,
                              userInfo: [NSUnderlyingErrorKey: NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)])
        let noUpdate = NSError(domain: SUSparkleErrorDomain, code: Int(SUError.noUpdateError.rawValue))
        func stopped(_ error: NSError, cycleFirst: Bool = false) {
            if cycleFirst { updates.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: error) }
            updates.updater(updater, didAbortWithError: error)
            if !cycleFirst { updates.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: error) }
        }

        updates.updaterDidNotFindUpdate(updater)
        check(updates.status == UpdateText.upToDate, "a good check says so")
        for day in 1...3 {
            stopped(feedMissing)
            check(updates.status == UpdateText.upToDate && !updates.checking,
                  "scheduled check \(day) with no published update page leaves the line alone: \(updates.status)")
        }
        stopped(offline, cycleFirst: true)
        check(updates.status == UpdateText.upToDate, "a scheduled check while offline leaves the line alone (cycle reported first): \(updates.status)")

        updates.checkStarted()
        check(updates.status == UpdateText.checking && updates.checking, "Check Now shows Checking…")
        stopped(feedMissing)
        check(updates.status == UpdateText.checkFailed && !updates.checking,
              "Check Now with no published update page: one line, \"\(UpdateText.checkFailed)\": \(updates.status)")
        updates.checkStarted()
        updates.updaterDidNotFindUpdate(updater)
        stopped(noUpdate)
        check(updates.status == UpdateText.upToDate && !updates.checking, "the next good check replaces the failure: \(updates.status)")
        updates.checkStarted()
        stopped(offline, cycleFirst: true)
        check(updates.status == UpdateText.unreachable, "Check Now while offline (cycle reported first): \"\(UpdateText.unreachable)\": \(updates.status)")
        updates.checkStarted()
        stopped(NSError(domain: SUSparkleErrorDomain, code: 1004))
        check(updates.status == UpdateText.checkFailed, "Check Now when resuming a downloaded update didn't work is not a network problem: \(updates.status)")
        updates.checkStarted()
        updates.updater(updater, didFinishUpdateCycleFor: .updatesInBackground, error: nil)
        check(updates.status != UpdateText.checking && !updates.checking && updates.statusLine != UpdateText.checking,
              "a check that ends without an answer never stays Checking…: \(updates.status)")

        updates.updater(updater, didFindValidUpdate: item)
        let available = UpdateText.available(item.displayVersionString)
        check(updates.status == available, "a found update says so")
        for code in [4007, 4008] {
            stopped(NSError(domain: SUSparkleErrorDomain, code: code))
            check(updates.status == available, "a cancelled install (\(code)) is not \"\(UpdateText.installFailed)\": \(updates.status)")
        }
        stopped(NSError(domain: SUSparkleErrorDomain, code: 3001))
        check(updates.status == UpdateText.installFailed, "an install that failed says so, unasked: \(updates.status)")
        stopped(NSError(domain: SUSparkleErrorDomain, code: 1005))
        check(updates.status == UpdateText.moveToApplications, "a copy that must move to Applications says so, unasked: \(updates.status)")
    }

    // MARK: D. Sources

    static func sources() {
        func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
        let updates = read("Sources/MacMemApp/Updates.swift")
        let app = read("Sources/MacMemApp/MacMemApp.swift")
        let commands = read("Sources/MacMemApp/AppCommands.swift")
        let quit = read("Sources/MacMemApp/PermissionRequests.swift")
        check(!updates.isEmpty && !app.isEmpty && !commands.isEmpty && !quit.isEmpty, "sources read (run from the repository root)")
        check(!updates.contains("pauseForUpdate") && !app.contains("pauseForUpdate"),
              "nothing pauses recording for an update before DayDream quits (no pauseForUpdate in Updates.swift or MacMemApp.swift)")
        check(updates.range(of: #"func updater\(_ updater:SPUUpdater,\s*willInstallUpdate item"#, options: .regularExpression) == nil,
              "Updates doesn't act on Sparkle's install call (the install runs only after the quit)")
        check(app.range(of: #"willTerminateNotification[^\n]*\n[^\n]*pauseCapture\([^\n]*commitTyping:true"#, options: .regularExpression) != nil,
              "the quit itself pauses recording and saves typed text (willTerminate)")
        check(updates.range(of: #"try updater\.start\(\)\n(\s*//[^\n]*\n)*\s*if !defaults\.bool\(forKey:Self\.quietUpdatesKey\) \{\n\s*updater\.automaticallyDownloadsUpdates=updater\.automaticallyChecksForUpdates"#, options: .regularExpression) != nil,
              "the first quiet-updates start() makes downloads follow the one switch (clears 0.1.3's saved \"never download\")")
        check(commands.range(of: #"struct AppCommands: Commands \{[^}]*AppQuit\.installQuitEventHandler\(\)"#, options: .regularExpression) != nil,
              "AppCommands installs DayDream's quit event handler")
        check(commands.contains("CommandGroup(replacing: .appTermination) { DaydreamQuitCommand(model: model) }")
              && commands.contains("var quit: () -> Void = { AppQuit.quit() }"),
              "DayDream ▸ Quit DayDream replaces AppKit's Quit and goes through AppQuit")
        check(quit.contains("forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication)")
              && quit.contains("AppQuit.quitForEvent()"),
              "the quit Apple event goes through AppQuit")
    }
}

extension UpdateQuitChecks {
    // MARK: E. Quiet updates

    static func quietUpdates() {
        guard let store = UQMemoryDefaults(inMemory: true) else { check(false, "preferences in memory"); return }
        let updates = Updates()
        updates.defaults = store
        var prepared = 0
        updates.prepareToQuit = { prepared += 1 }
        let (updater, item) = sparkle(updates)
        check(updates.waiting == nil, "no update waiting at first")
        var installs = 0
        let taken = updates.updater(updater, willInstallUpdateOnQuit: item, immediateInstallationBlock: { installs += 1 })
        check(taken, "DayDream takes the downloaded update (Sparkle shows nothing and installs at the quit)")
        check(updates.waiting == .restart(version: item.displayVersionString) && installs == 0 && prepared == 0,
              "a downloaded update waits for Restart to Update: nothing installs, nothing closes")
        check(updates.statusLine == UpdateText.ready(item.displayVersionString) && !updates.checking,
              "the status line says it's ready: \(updates.statusLine ?? "nil")")
        check(updates.waiting?.title == UpdateText.restartTitle, "its one action is Restart to Update")
        // This copy has no updater (no update keys), so the action does nothing: only a configured copy installs.
        updates.actOnWaiting()
        check(installs == 0, "Restart to Update does nothing in a copy without updates")
        check(!updates.standardUserDriverShouldHandleShowingScheduledUpdate(item, andInImmediateFocus: true)
              && !updates.standardUserDriverShouldHandleShowingScheduledUpdate(item, andInImmediateFocus: false)
              && updates.supportsGentleScheduledUpdateReminders,
              "a scheduled update never opens Sparkle's window by itself, in focus or not")
        updates.standardUserDriverWillFinishUpdateSession()
        check(updates.waiting == .restart(version: item.displayVersionString), "a finished session leaves a downloaded update waiting")
        updates.updateWaiting(.review(version: "0.1.5 Beta"))
        check(updates.waiting?.title == UpdateText.reviewTitle && updates.statusLine == UpdateText.available("0.1.5 Beta"),
              "an update Sparkle can't install by itself is offered as Update DayDream…")
        updates.standardUserDriverDidReceiveUserAttention(forUpdate: item)
        check(updates.waiting == nil, "once the person opened Sparkle's window for it, Update DayDream… goes")
        // The menu bar menu: the row only while an update waits, right above Quit; never in the isolated preview.
        typealias Menu = MenuBarMenu
        let plain = Menu.rows(isolated: false, onboardingComplete: true, development: false).map(\.title)
        let waiting = Menu.rows(isolated: false, onboardingComplete: true, development: false, update: UpdateText.restartTitle).map(\.title)
        check(!plain.contains(UpdateText.restartTitle), "no update waiting: no Restart to Update row")
        check(waiting == plain.dropLast() + [UpdateText.restartTitle, "Quit DayDream"], "Restart to Update sits right above Quit: \(waiting)")
        check(Menu.rows(isolated: true, onboardingComplete: true, development: false, update: UpdateText.restartTitle).map(\.title) == ["Quit DayDream"],
              "the isolated preview never offers it")
        check(Menu.rows(isolated: false, onboardingComplete: true, development: false, update: UpdateText.restartTitle).last?.action == .quit
              && Menu.rows(isolated: false, onboardingComplete: true, development: false, update: UpdateText.restartTitle).dropLast().last?.action == .update,
              "the row runs the update action")
    }
}

// MARK: - The child copy (a SwiftUI app with DayDream's menus and a Settings-style sheet)

@MainActor enum UQChild {
    static var variant = ""
    static let sheet = UQSheetState()
    static var window: NSWindow?
    static var recording = true
    static var keep: [AnyObject] = []
    /// The controls and the relaunch with AppKit's own handler run without DayDream's quit event handler.
    static var installsHandler: Bool { !["terminate-control", "event-control", "relaunch"].contains(variant) }

    static func say(_ line: String) { print(line); fflush(stdout) }

    static func start() {
        // As MacMemApp does: a quit closes the Settings sheet's own state first.
        if variant != "event-unwired" { AppQuit.willQuit = { sheet.shown = false } }
        let w = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: UQSheetHost(state: sheet))
        w.orderFrontRegardless()
        window = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { MainActor.assumeIsolated { quit() } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
            MainActor.assumeIsolated {
                say("STILL RUNNING attached=\(window?.attachedSheet != nil)")
                (keep.first as? Updates)?.defaults.removeObject(forKey: UpdateResume.key)
            }
            exit(3)
        }
    }

    static func quit() {
        say("attached=\(window?.attachedSheet != nil)")
        switch variant {
        case "terminate-control": NSApp.terminate(nil)
        case "event-control", "event", "event-unwired": sendQuitEvent(reason: nil)
        case "event-restart": sendQuitEvent(reason: OSType(kAERestart))
        case "event-logout": sendQuitEvent(reason: OSType(kAEReallyLogOut))
        case "menu-item":
            guard let (menu, index) = quitItem() else { say("no ⌘Q item"); exit(5) }
            say("item=\(menu.items[index].title) key=\(menu.items[index].keyEquivalent)")
            menu.performActionForItem(at: index)
        case "menu-key":
            let event = CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true)!  // Q
            event.flags = .maskCommand
            say("key handled=\(NSApp.mainMenu?.performKeyEquivalent(with: NSEvent(cgEvent: event)!) ?? false)")
        case "relaunch", "relaunch-handler": relaunch()
        default: say("unknown variant"); exit(6)
        }
    }

    /// The app menu's ⌘Q item.
    static func quitItem() -> (NSMenu, Int)? {
        guard let menu = NSApp.mainMenu?.items.first?.submenu else { return nil }
        guard let index = menu.items.firstIndex(where: {
            $0.keyEquivalent == "q" && $0.keyEquivalentModifierMask.intersection(.deviceIndependentFlagsMask) == .command
        }) else { return nil }
        return (menu, index)
    }

    /// The quit Apple event, as the Dock, loginwindow (log out, restart) and Sparkle's installer send it.
    static func sendQuitEvent(reason: OSType?) {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEQuitApplication),
                                           targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        if let reason { event.setParam(NSAppleEventDescriptor(enumCode: reason), forKeyword: AEKeyword(kAEQuitReason)) }
        do {
            let reply = try event.sendEvent(options: [.waitForReply], timeout: 3)
            say("event reply errn=\(reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)).map { String($0.int32Value) } ?? "none")")
        } catch { say("event threw \((error as NSError).code)") }
    }

    /// Install and Relaunch: Sparkle's install call, then the relaunch call, then (from the installer) the quit event.
    static func relaunch() {
        let updates = Updates()
        updates.isRecording = { recording }
        if let memory = UQMemoryDefaults(inMemory: true) { updates.defaults = memory }
        let (updater, item) = UpdateQuitChecks.sparkle(updates)
        keep = [updates, updater]
        (updates as SPUUpdaterDelegate).updater?(updater, willInstallUpdate: item)
        updates.updaterWillRelaunchApplication(updater)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            MainActor.assumeIsolated {
                let marker = (keep.first as? Updates)?.defaults.dictionary(forKey: UpdateResume.key) != nil
                say("relaunch: attached=\(window?.attachedSheet != nil) recording=\(recording) marker=\(marker)")
                sendQuitEvent(reason: nil)
            }
        }
    }

    static func terminating() {
        say("WILL TERMINATE recording=\(recording)")
        (keep.first as? Updates)?.defaults.removeObject(forKey: UpdateResume.key)
    }
}

final class UQSheetState: ObservableObject { @Published var shown = true }

/// Preferences that live only in this process, so no check writes a preferences file (a scratch HOME doesn't keep
/// UserDefaults out of ~/Library/Preferences on this macOS).
final class UQMemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    init?(inMemory: Bool) { super.init(suiteName: nil) }
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { values[defaultName] as? [String: Any] }
    override func set(_ value: Any?, forKey defaultName: String) { values[defaultName] = value }
    override func removeObject(forKey defaultName: String) { values[defaultName] = nil }
}

struct UQSheetHost: View {
    @ObservedObject var state: UQSheetState
    var body: some View {
        Text("memory window").frame(width: 400, height: 300)
            .sheet(isPresented: $state.shown) { Text("Settings").frame(width: 300, height: 200) }
    }
}

/// The child's menus: DayDream's, with the quit event handler installed the way AppCommands installs it
/// (AppCommands itself is compiled out of the checks with the app's scenes).
struct UQChildCommands: Commands {
    var body: some Commands {
        let _ = UQChild.installsHandler ? AppQuit.installQuitEventHandler() : ()
        DaydreamCommands(model: nil)
    }
}

struct UQChildApp: App {
    @NSApplicationDelegateAdaptor(UQChildDriver.self) private var driver
    var body: some Scene {
        Settings { EmptyView() }.commands { UQChildCommands() }
    }
}

@MainActor final class UQChildDriver: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
    func applicationDidFinishLaunching(_ notification: Notification) { UQChild.start() }
    func applicationWillTerminate(_ notification: Notification) { UQChild.terminating() }
}
