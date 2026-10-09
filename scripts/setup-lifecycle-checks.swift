// DD-RECIPE: APP
// setup-lifecycle-checks (rc-018 RC3, package A: lifecycle, restart, focus). The owner's night of 10/8-10/9: the restart
// raced macOS's own "Quit & Reopen / Later" sheet; setup came back behind System Settings (macOS's own Quit & Reopen
// relaunched DayDream at 00:49:31); recording was silently off after a restart; Chrome's Allow could be pressed while
// DayDream was about to quit; stale saved state skipped steps; System Settings left open filed the drop under an old
// copy; the real DayDream was quit instead of the Live Test (identical menu bar icons). Rows:
//   R. Rules, pure: the relaunch context (saved, read once, too old, from the future), where setup's window goes on
//      today's screens, when a decided restart may go (`SelfRestartGate`), the restart budget, System Settings older
//      than this copy, 0.1.7's drag copies in Caches (a scratch folder), copies System Settings never lists, the Live
//      Test mark (only with Info.plist's DaydreamLiveTest; the release Info.plist has none).
//   F. The focus policy (`SetupFocus`) with its seams: the memory window held out of sight while setup is unfinished and
//      shown when setup closes or finishes or from the Dock; a relaunch's setup placed where it was, on its page, key and
//      in front, once; the hand-back (once per permission, never with a sheet, a password window or a reopen pending);
//      nothing activates during a press; a read activation started waits for mouse-up (300 ms at most).
//   M. The REAL MemoryViewModel (check seams: in-memory restart defaults, no event tap, fake reads): the restart waits
//      while System Settings shows a sheet and goes once it is gone (Later), goes after 10 s when no sheet is ever seen
//      or it can't be read (macOS's alert is its privacy extension's; review 10/9), and after 10 s under one left up,
//      waits during a press, a drag and a Chrome question; setup says "Restarting…", disabled, with Chrome's Allow
//      disabled and asking nothing; its context is saved first (and on any quit while setup is open); a restart still
//      alive after 5 s ends its helper and offers Quit & Reopen; at most 2 restarts in 30 minutes; never under the
//      person's open window; "keys not arriving" restarts in the background; recording wanted survives a permission
//      comeback restart, and past the comeback's 10 minutes (review 10/9); a first setup forgets an earlier install's
//      Chrome answer, but not on its own relaunch; Settings › Permissions hands its presses to the permissions window.
//      F also: Open DayDream in the menu bar brings an unfinished setup forward; a held-back hand-back comes once it may.
//   S. Sources: the drag guide's celebration activates nothing (setup's hand-back does); the sheet read never touches
//      Accessibility before it is allowed; the Dock and the menu bar go through the held window; the menu bar label.
// Nothing here activates, shows a window, reads System Settings, quits an app or relaunches: every such call is a seam
// (check builds start them quiet) and every window is hosted hidden (never ordered in).
import AppKit
import Combine
import CSQLite
import MemoryCore
import MemoryUI
import SwiftUI

@MainActor enum Report {
    static var passed = 0, failed = 0
    static func check(_ ok: Bool, _ id: String, _ message: @autoclosure () -> String) {
        if ok { passed += 1; print("PASS [\(id)] \(message())") } else { failed += 1; print("FAIL [\(id)] \(message())") }
        fflush(stdout)
    }
}
@MainActor func check(_ ok: Bool, _ id: String, _ message: @autoclosure () -> String) { Report.check(ok, id, message()) }
func stop(_ message: String) -> Never { fflush(stdout); FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)); exit(1) }
@MainActor func tick(_ seconds: Double = 0.01) async throws { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
func makePrivateDirectory(_ url: URL) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}
func source(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }
/// The text of the declaration that starts with `head`, to its closing brace.
func body(of head: String, in text: String) -> String {
    guard let start = text.range(of: head) else { return "" }
    var depth = 0, seen = false, i = start.lowerBound
    while i < text.endIndex {
        let c = text[i]
        if c == "{" { depth += 1; seen = true } else if c == "}" { depth -= 1; if seen && depth == 0 { return String(text[start.lowerBound...i]) } }
        i = text.index(after: i)
    }
    return ""
}

/// What the seams read. `granted`: both permissions.
enum Seams {
    nonisolated(unsafe) static var granted = true
    nonisolated(unsafe) static var restarts = 0, backgroundRestarts = 0, helperCancels = 0
    nonisolated(unsafe) static var restartWorks = true
    nonisolated(unsafe) static var sheet: Bool? = false
    /// macOS's sheet up until this moment, then gone (the person pressed Later): `flashSheet`.
    nonisolated(unsafe) static var sheetUntil: Date?
    static func sheetNow() -> Bool? { if let until = sheetUntil { return Date() < until }; return sheet }
    /// The sheet shows for `seconds` from now, then goes (Later): a decided restart may go at once after it.
    static func flashSheet(_ seconds: Double = 0.5) { sheetUntil = Date().addingTimeInterval(seconds) }
    nonisolated(unsafe) static var auth = false, pressing = false, dragging = false, windowsAllow = true
    nonisolated(unsafe) static var lastCapture: AnyObject?
    static func reset() {
        granted = true; restarts = 0; backgroundRestarts = 0; helperCancels = 0; restartWorks = true
        sheet = false; sheetUntil = nil; auth = false; pressing = false; dragging = false; windowsAllow = true
    }
}
/// Restart defaults kept in memory only (no suite, nothing reaches cfprefsd).
final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    init(inMemory: Void = ()) { super.init(suiteName: nil)! }
    override func object(forKey defaultName: String) -> Any? { values[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) {
        if let value { values[defaultName] = value } else { values.removeValue(forKey: defaultName) }
    }
    override func removeObject(forKey defaultName: String) { values.removeValue(forKey: defaultName) }
    override func dictionary(forKey defaultName: String) -> [String: Any]? { values[defaultName] as? [String: Any] }
    override func string(forKey defaultName: String) -> String? { values[defaultName] as? String }
    override func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    override func bool(forKey defaultName: String) -> Bool { (values[defaultName] as? NSNumber)?.boolValue ?? false }
    override func set(_ value: Bool, forKey defaultName: String) { values[defaultName] = value }
    override func double(forKey defaultName: String) -> Double { (values[defaultName] as? NSNumber)?.doubleValue ?? 0 }
    override func set(_ value: Double, forKey defaultName: String) { values[defaultName] = value }
    override func integer(forKey defaultName: String) -> Int { (values[defaultName] as? NSNumber)?.intValue ?? 0 }
    override func set(_ value: Int, forKey defaultName: String) { values[defaultName] = value }
}
/// A Chrome that is installed and closed; Allow's open is held until the check lets it answer.
@MainActor final class FakeChrome {
    var asks = 0, opens = 0
    var heldOpen: ((Bool) -> Void)?
    var environment: ChromeAccessEnvironment {
        var env = ChromeAccessEnvironment(running: { nil }, verify: { _ in true }, status: { _ in -1744 }, ask: { _ in self.asks += 1; return 0 },
                                          background: { $0() }, main: { $0() })
        env.installed = { true }
        env.openChrome = { done in self.opens += 1; self.heldOpen = done }
        return env
    }
}
struct Opened { let model: MemoryViewModel; let chrome: FakeChrome; let intent: UserDefaults? }

@main @MainActor struct SetupLifecycleChecks {
    static var out = URL(fileURLWithPath: "/")

    static func main() async throws {
        DispatchQueue.global().asyncAfter(deadline: .now() + 300) {
            FileHandle.standardError.write(Data("FAIL: setup-lifecycle-checks watchdog expired after 300s\n".utf8)); exit(2)
        }
        let env = ProcessInfo.processInfo.environment
        let shared = ["/private/tmp/" + "day" + "dream-", "/tmp/" + "day" + "dream-"]
        guard let outPath = env["DD_CHECK_OUT"], outPath.hasPrefix("/"), !shared.contains(where: { outPath.hasPrefix($0) }) else {
            stop("DD_CHECK_OUT is not a private output directory; run this check through run-checks.sh")
        }
        guard let fixed = env["CFFIXED_USER_HOME"], env["HOME"] == fixed, fixed != "/Users/" + NSUserName(),
              FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path == URL(fileURLWithPath: fixed).standardizedFileURL.path else {
            stop("HOME and CFFIXED_USER_HOME must name one synthetic home; run this check through run-checks.sh")
        }
        out = URL(fileURLWithPath: outPath, isDirectory: true).appendingPathComponent("setup-lifecycle", isDirectory: true)
        try makePrivateDirectory(out)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        MemoryViewModel.permissionsGranted = { Seams.granted }
        MemoryViewModel.permissionRead = { PermissionSnapshot(accessibility: Seams.granted, inputMonitoring: Seams.granted) }
        DaydreamOnboarding.readPermissions = { (Seams.granted, Seams.granted) }
        DaydreamOnboarding.qualifiesForChecks = false
        MemoryViewModel.startInput = { capture in Seams.lastCapture = capture; return true }
        MemoryViewModel.readLaunchLocation = { .applications }
        MemoryViewModel.canReopen = { true }
        MemoryViewModel.performAutoRelaunch = { _ in Seams.restarts += 1; return Seams.restartWorks }
        MemoryViewModel.performBackgroundRelaunch = { _ in Seams.backgroundRestarts += 1; return Seams.restartWorks }
        MemoryViewModel.cancelRelaunchHelper = { Seams.helperCancels += 1 }
        MemoryViewModel.restartReads = SelfRestartReads(sheetUp: { Seams.sheetNow() }, authOnScreen: { Seams.auth }, pressing: { Seams.pressing },
                                                        dragging: { Seams.dragging }, windowsAllow: { _ in Seams.windowsAllow })
        // Setup finished, in the registration domain only (in memory); the first-setup rows set it off in the scratch HOME.
        UserDefaults.standard.register(defaults: [MemoryViewModel.setupCompletedKey: true])

        let only = env["DD_LIFECYCLE_ONLY"].map { Set($0.split(separator: ",").map(String.init)) }
        func runs(_ part: String) -> Bool { only?.contains(part) ?? true }
        if runs("R") { rules() }
        if runs("F") { try await focus() }
        if runs("S") { sources() }
        if runs("M") {
            try await restartWaitsForSheet()
            try await restartUnreadableSheet()
            try await restartWaitsForPress()
            try await restartWaitsForChrome()
            try await restartStillAlive()
            try await restartBudgetAndWindows()
            try await keysNotArriving()
            try await recordingSurvivesRestart()
            try await relaunchRecordsAgain()
            try await firstSetupForgetsChrome()
            try await setupLinesAndDeferral()
            try await settingsHandsToPermissionsWindow()
            try await recordingSurvivesComebackExpiry()
        }
        print("setup-lifecycle: \(Report.passed) passed, \(Report.failed) failed")
        fflush(stdout)
        exit(Report.failed == 0 ? 0 : 1)
    }

    // MARK: Harness

    static func open(_ name: String, intent: UserDefaults? = nil, settle: Bool = true) async throws -> Opened {
        let memory = out.appendingPathComponent(name + "-" + UUID().uuidString, isDirectory: true)
        try makePrivateDirectory(memory)
        setenv("MAC_MEM_HOME", memory.path, 1)
        MemoryViewModel.launchIntentDefaults = intent
        let model = MemoryViewModel()
        MemoryViewModel.launchIntentDefaults = nil
        // The screen reads unlocked and on console (this Mac's real screen may be locked while the check runs).
        model.wakeSystem = WakeSystem(screenLocked: { false }, onConsole: { true },
                                      after: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) }, now: { Date() })
        let chrome = FakeChrome()
        model.chromeAccessEnvironment = chrome.environment
        if model.anotherCopyOpen { check(false, "harness", "\(name) opened its own history") }
        if settle {
            let end = Date().addingTimeInterval(3)
            while model.history.busy || model.historyOpening, Date() < end { try await tick(0.05) }
            try await tick(0.15)
        }
        return Opened(model: model, chrome: chrome, intent: intent)
    }
    static func close(_ o: Opened) async throws {
        Seams.granted = true
        o.model.stopCapture()
        try await tick(0.05)
    }
    static func waitFor(_ seconds: Double, _ done: () -> Bool) async throws -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { if done() { return true }; try await tick(0.02) }
        return done()
    }
    /// Input Monitoring off at launch, turned on 2.4 s later (permission-blip-checks' path): DayDream decides to restart.
    static func decidedRestart(_ name: String, before: (() -> Void)? = nil) async throws -> Opened {
        MemoryViewModel.autoRelaunchDefaults = MemoryDefaults()
        Seams.granted = false
        let t0 = Date()
        let o = try await open(name, settle: false)
        while Date() < t0.addingTimeInterval(2.4) { try await tick(0.05) }
        before?()
        Seams.granted = true
        o.model.refreshCaptureStatus()
        return o
    }
    static func host<V: View>(_ view: V, size: NSSize = NSSize(width: 660, height: 600)) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        let host = NSHostingView(rootView: view)
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        return window
    }
    /// A fresh focus state with recorders standing in for activation and ordering in.
    final class Fronts { var calls: [(NSWindow, Bool)] = []; var activations = 0 }
    static func freshFocus() -> Fronts {
        let f = SetupFocus.shared, rec = Fronts()
        f.resetForChecks()
        f.activate = { rec.activations += 1 }
        f.front = { window, key in rec.calls.append((window, key)) }
        return rec
    }
    static func hiddenWindow(_ rect: NSRect = NSRect(x: 0, y: 0, width: 660, height: 560)) -> NSWindow {
        let w = NSWindow(contentRect: rect, styleMask: [.titled, .closable], backing: .buffered, defer: true)
        w.isReleasedWhenClosed = false
        return w
    }

    // MARK: R. Rules

    static func rules() {
        // R1 the relaunch context
        let d = MemoryDefaults(), now = Date()
        let c = SetupRelaunchContext(reason: .setup, page: DaydreamOnboardingPage.apps.rawValue, frame: [100, 200, 660, 560],
                                     screen: [0, 0, 1440, 900], recording: true, savedAt: now.timeIntervalSince1970)
        c.save(d)
        let read = SetupRelaunchContext.consume(d, now: now.addingTimeInterval(20))
        check(read == c && read?.setupPage == .apps && read?.setupFrame == CGRect(x: 100, y: 200, width: 660, height: 560),
              "R1-context", "a relaunch 20 s after the quit reads setup's page, frame and recording: \(String(describing: read))")
        check(d.object(forKey: SetupRelaunchContext.key) == nil && SetupRelaunchContext.consume(d, now: now) == nil,
              "R1-context", "…read once: it is removed as it is read")
        c.save(d)
        check(SetupRelaunchContext.consume(d, now: now.addingTimeInterval(61)) == nil && d.object(forKey: SetupRelaunchContext.key) == nil,
              "R1-context", "older than 60 s: an ordinary launch (and removed)")
        c.save(d)
        check(SetupRelaunchContext.consume(d, now: now.addingTimeInterval(-30)) == nil, "R1-context", "saved in the future (a clock that moved): ignored")
        d.set(Data("x".utf8), forKey: SetupRelaunchContext.key)
        check(SetupRelaunchContext.consume(d, now: now) == nil && d.object(forKey: SetupRelaunchContext.key) == nil, "R1-context", "unreadable: ignored and removed")

        // R2 where setup's window goes
        let main = (frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: CGRect(x: 0, y: 0, width: 1440, height: 875))
        let side = (frame: CGRect(x: 1440, y: 0, width: 1920, height: 1080), visible: CGRect(x: 1440, y: 0, width: 1920, height: 1055))
        let size = CGSize(width: 660, height: 560)
        let kept = SetupRelaunchContext.placed(saved: CGRect(x: 1600, y: 300, width: 660, height: 560), size: size, savedScreen: side.frame, screens: [main, side])
        check(kept.origin == CGPoint(x: 1600, y: 300), "R2-place", "the saved frame on a screen that is still there: kept, \(kept)")
        let gone = SetupRelaunchContext.placed(saved: CGRect(x: 1600, y: 300, width: 660, height: 560), size: size, savedScreen: side.frame, screens: [main])
        check(main.visible.contains(gone), "R2-place", "its screen is gone: moved onto a screen there is, inside it: \(gone)")
        let half = SetupRelaunchContext.placed(saved: CGRect(x: 1200, y: 600, width: 660, height: 560), size: size, savedScreen: main.frame, screens: [main, side])
        check(main.visible.contains(half), "R2-place", "half off its screen (the menu bar, the edge): moved inside its own screen: \(half)")

        // R3 when a decided restart may go
        typealias G = SelfRestartGate
        check(G.limit == 10, "R3-gate", "the restart goes after \(G.limit) s at the latest")
        check(G.decide(.init(sheetUp: true, waited: 0.5)) == .wait && G.decide(.init(sheetUp: true, waited: 9.9, sheetSeen: true)) == .wait
              && G.decide(.init(sheetUp: true, waited: 10, sheetSeen: true)) == .now,
              "R3-gate", "System Settings shows a sheet (macOS's Quit & Reopen / Later): the restart waits, up to 10 s (FIX-PLAN A1; the line says it restarts by itself)")
        check(G.decide(.init(sheetUp: false, waited: 0.4, sheetSeen: true)) == .now, "R3-gate", "the sheet went (Later): the restart goes at once")
        check(G.decide(.init(sheetUp: false, waited: 1.5)) == .wait && G.decide(.init(sheetUp: false, waited: 9.9)) == .wait
              && G.decide(.init(sheetUp: false, waited: 10)) == .now,
              "R3-gate", "no sheet ever seen (macOS's alert may be its privacy extension's, not System Settings' sheet): it waits 10 s, never the old 1.5 s race")
        check(G.decide(.init(sheetUp: nil, waited: 9.9)) == .wait && G.decide(.init(sheetUp: nil, waited: 10)) == .now,
              "R3-gate", "the sheet can't be read (no Accessibility yet): the restart goes after 10 s")
        // The window server's alert (no permission needed): System Settings' privacy extension's, or a sheet of its own.
        func win(_ pid: Int, _ owner: String, _ layer: Int, _ r: CGRect) -> [String: Any] {
            [kCGWindowOwnerPID as String: pid, kCGWindowOwnerName as String: owner, kCGWindowLayer as String: layer,
             kCGWindowBounds as String: r.dictionaryRepresentation as NSDictionary]
        }
        let mainSS = win(500, "System Settings", 0, CGRect(x: 400, y: 200, width: 715, height: 640))
        let noBundle: (pid_t) -> String? = { _ in nil }
        check(SystemSettingsRead.alert(in: [mainSS, win(611, "SecurityPrivacyExtension", 0, CGRect(x: 600, y: 300, width: 260, height: 290))], settingsPID: 500, ownPID: 1, bundleOf: noBundle)
              && SystemSettingsRead.alert(in: [mainSS, win(500, "System Settings", 0, CGRect(x: 540, y: 228, width: 420, height: 180))], settingsPID: 500, ownPID: 1, bundleOf: noBundle)
              && SystemSettingsRead.alert(in: [mainSS, win(612, "x", 8, CGRect(x: 600, y: 300, width: 260, height: 290))], settingsPID: 500, ownPID: 1,
                                          bundleOf: { $0 == 612 ? "com.apple.settings.PrivacySecurity.extension" : nil }),
              "R3-alert", "macOS's Quit & Reopen alert reads as up from the window server: its privacy extension's window, a sheet of System Settings, or a window of a com.apple.settings extension")
        check(!SystemSettingsRead.alert(in: [mainSS], settingsPID: 500, ownPID: 1, bundleOf: noBundle)
              && !SystemSettingsRead.alert(in: [mainSS, win(1, "DayDream", 0, CGRect(x: 0, y: 0, width: 360, height: 120)),
                                                win(77, "Finder", 0, CGRect(x: 0, y: 0, width: 400, height: 300)),
                                                win(500, "System Settings", 25, CGRect(x: 0, y: 0, width: 300, height: 100))], settingsPID: 500, ownPID: 1, bundleOf: noBundle)
              && !SystemSettingsRead.alert(in: [], settingsPID: nil, ownPID: 1, bundleOf: noBundle),
              "R3-alert", "System Settings' own window alone, DayDream's own panel, another app's window or a menu-level window: no alert")
        for (name, i) in [("a press", G.Inputs(sheetUp: false, pressing: true, waited: 30, sheetSeen: true)),
                          ("a drag", G.Inputs(sheetUp: false, dragging: true, waited: 30, sheetSeen: true)),
                          ("a Chrome question", G.Inputs(sheetUp: false, chromeAsking: true, waited: 30, sheetSeen: true)),
                          ("a password window", G.Inputs(sheetUp: false, authOnScreen: true, waited: 30, sheetSeen: true))] {
            check(G.decide(i) == .wait, "R3-gate", "never during \(name)")
        }

        // R4 the restart budget
        let b = MemoryDefaults()
        check(SelfRestartBudget.allowed(b, now: now), "R4-budget", "no restart yet: allowed")
        SelfRestartBudget.note(b, now: now.addingTimeInterval(-600))
        check(SelfRestartBudget.allowed(b, now: now), "R4-budget", "one in the last 30 minutes: allowed")
        SelfRestartBudget.note(b, now: now.addingTimeInterval(-60))
        check(!SelfRestartBudget.allowed(b, now: now), "R4-budget", "two in the last 30 minutes: no third (Quit & Reopen instead)")
        check(SelfRestartBudget.allowed(b, now: now.addingTimeInterval(1800)), "R4-budget", "30 minutes after the first: allowed again")

        // R5 System Settings older than this copy
        let installed = now.addingTimeInterval(-120)
        check(SystemSettingsAge.stale(settingsLaunched: now.addingTimeInterval(-3600), bundleDates: [nil, installed, now.addingTimeInterval(-9999)]),
              "R5-settings-age", "System Settings opened before this copy was installed: stale")
        check(!SystemSettingsAge.stale(settingsLaunched: now, bundleDates: [installed]) && !SystemSettingsAge.stale(settingsLaunched: nil, bundleDates: [installed])
              && !SystemSettingsAge.stale(settingsLaunched: now.addingTimeInterval(-3600), bundleDates: [nil, nil]),
              "R5-settings-age", "opened after it, not running, or no install date known: nothing to say")
        check(SystemSettingsAge.line == "Quit System Settings and open it again." && SystemSettingsAge.quitTitle == "Quit",
              "R5-settings-age", "the line and its button")

        // R6 0.1.7's drag copies in Caches
        do {
            let caches = out.appendingPathComponent("caches-\(UUID().uuidString)", isDirectory: true)
            try makePrivateDirectory(caches)
            func app(_ folder: String, id: String?, extra: String? = nil, name: String = "DayDream.app") throws -> URL {
                let dir = caches.appendingPathComponent(folder, isDirectory: true)
                let contents = dir.appendingPathComponent(name + "/Contents", isDirectory: true)
                try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
                var plist: [String: Any] = ["CFBundlePackageType": "APPL", "CFBundleExecutable": "DayDream"]
                if let id { plist["CFBundleIdentifier"] = id }
                try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
                if let extra { try Data().write(to: dir.appendingPathComponent(extra)) }
                return dir
            }
            let own = try app("com.apple.SwiftUI.Drag-AAAA", id: DaydreamIdentity.bundleID, extra: ".DS_Store")
            let test = try app("com.apple.SwiftUI.Drag-BBBB", id: DaydreamIdentity.bundleID + ".livetest")
            let other = try app("com.apple.SwiftUI.Drag-CCCC", id: "com.example.other")
            let crowded = try app("com.apple.SwiftUI.Drag-DDDD", id: DaydreamIdentity.bundleID, extra: "notes.txt")
            // Two DayDream apps and nothing else: not a drag copy (whichever the folder lists first, both are DayDream's).
            let twoApps = try app("com.apple.SwiftUI.Drag-DDDE", id: DaydreamIdentity.bundleID)
            _ = try app("com.apple.SwiftUI.Drag-DDDE", id: DaydreamIdentity.bundleID, name: "DayDream 2.app")
            let named = try app("SomethingElse-EEEE", id: DaydreamIdentity.bundleID)
            let lookalike = try app("com.apple.SwiftUI.Drag-FFFF", id: DaydreamIdentity.bundleID + "x")
            let linked = caches.appendingPathComponent("com.apple.SwiftUI.Drag-GGGG", isDirectory: true)
            try FileManager.default.createDirectory(at: linked, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: linked.appendingPathComponent("DayDream.app"), withDestinationURL: own.appendingPathComponent("DayDream.app"))
            let found = Set(DragCopyLeftovers.found(caches: caches).map { $0.standardizedFileURL.lastPathComponent })
            check(found == [own.lastPathComponent, test.lastPathComponent], "R6-leftovers",
                  "only folders named com.apple.SwiftUI.Drag-* holding nothing but a DayDream app: \(found.sorted())")
            let removed = DragCopyLeftovers.clean(caches: caches)
            let fm = FileManager.default
            check(removed == 2 && !fm.fileExists(atPath: own.path) && !fm.fileExists(atPath: test.path)
                  && [other, crowded, twoApps, named, lookalike, linked].allSatisfy { fm.fileExists(atPath: $0.path) },
                  "R6-leftovers", "cleaning removes those two and nothing else (another app, a folder with more in it, two apps, another name, a look-alike id, a link): \(removed)")
            check(DragCopyLeftovers.clean(caches: caches.appendingPathComponent("missing")) == 0, "R6-leftovers", "no Caches folder: nothing happens")
        } catch { check(false, "R6-leftovers", "the scratch caches could not be made: \(error)") }

        // R7 copies System Settings never lists
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for path in [home + "/.Trash/DayDream.app", "/Volumes/X/.Trashes/501/DayDream.app",
                     "/private/var/folders/xy/T/AppTranslocation/1234/d/DayDream.app", home + "/Library/Caches/com.apple.SwiftUI.Drag-1/DayDream.app",
                     home + "/Library/Caches/com.getnorthlight.daydream/org.sparkle-project.Sparkle/Installation/x/DayDream.app"] {
            check(PermissionRowHelp.ignoredCopy(URL(fileURLWithPath: path)), "R7-lookalikes", "never counted as a copy System Settings lists: \(path)")
        }
        for path in ["/Applications/DayDream.app", "/Volumes/X/live/DayDream.app", home + "/Applications/DayDream Live Test.app"] {
            check(!PermissionRowHelp.ignoredCopy(URL(fileURLWithPath: path)), "R7-lookalikes", "still counted: \(path)")
        }
        let copies = PermissionRowHelp.lookAlikes(appURL: URL(fileURLWithPath: "/Applications/DayDream.app"), ids: ["a"],
                                                  copies: { _ in [URL(fileURLWithPath: home + "/.Trash/DayDream.app"), URL(fileURLWithPath: "/Volumes/X/live/DayDream.app")] })
        check(copies.map(\.path) == ["/Volumes/X/live/DayDream.app"], "R7-lookalikes", "the look-alike count leaves out the Trash: \(copies.map(\.path))")
        check(body(of: "public static func ignoredCopy(", in: source("Sources/MemoryUI/PermissionSetup.swift")).contains(".volumeIsReadOnlyKey"),
              "R7-lookalikes", "a copy on a read-only volume (a mounted disk image) is left out too")

        // R9 the words (owner taste: plain, short)
        check(PermissionRelaunch.autoText == "DayDream restarts by itself. You can click Later." && DaydreamOnboarding.restartingTitle == "Restarting…",
              "R9-copy", "the restart line says macOS's Later is fine; the button says Restarting…")
        for line in [PermissionRelaunch.autoText, DaydreamOnboarding.restartingTitle, SystemSettingsAge.line, SystemSettingsAge.quitTitle, LiveTestMark.text] {
            check(line.count <= 60 && !line.contains("**") && !line.lowercased().contains("draft") && !line.lowercased().contains("never leave")
                  && !line.lowercased().contains("never uploaded") && !line.contains("free memory"), "R9-copy", "short and plain: \(line)")
        }

        // R8 the Live Test mark
        check(LiveTestMark.shown(info: ["DaydreamLiveTest": true]) && !LiveTestMark.shown(info: ["DaydreamLiveTest": false])
              && !LiveTestMark.shown(info: [:]) && !LiveTestMark.shown(info: nil), "R8-livetest", "\"TEST\" only with Info.plist's DaydreamLiveTest")
        let plist = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: "packaging/Info.plist")), format: nil)) as? [String: Any]
        check(plist != nil && plist?["DaydreamLiveTest"] == nil && !LiveTestMark.shown(info: plist), "R8-livetest",
              "the release Info.plist has no such key: the public menu bar is unchanged")
        let mark = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { r in NSColor.black.setFill(); r.fill(); return true }
        let composed = LiveTestMark.compose(mark)
        check(composed.isTemplate && composed.size.height == 18 && composed.size.width > 30 && LiveTestMark.compose(mark) === composed && LiveTestMark.text == "TEST",
              "R8-livetest", "the mark and \"TEST\" are one template image (menu bar colors), made once: \(composed.size)")
    }

    // MARK: F. The focus policy

    static func focus() async throws {
        let f = SetupFocus.shared
        // F1 the memory window held while setup is unfinished
        var rec = freshFocus()
        let memory = hiddenWindow(), setup = hiddenWindow()
        f.holdMemoryAtLaunch()
        f.memoryWindowAppeared(memory)
        check(memory.alphaValue == 0 && f.heldMemoryWindow === memory, "F1-hold", "the memory window is clear from the moment it exists")
        try await tick(0.05)
        check(!memory.isVisible && memory.alphaValue == 1 && f.holdsMemory, "F1-hold", "…then ordered out (never drawn), still held")
        f.setupShown(setup, page: .permissions, unfinished: true)
        check(f.reopenFromDock() && rec.calls.count == 1 && rec.calls[0].0 === setup && rec.calls[0].1 && f.activations == ["dock"] && f.holdsMemory,
              "F1-hold", "the Dock while setup is open: setup comes forward, key; the memory window stays held")
        rec.calls = []
        f.setupClosed()
        check(rec.calls.count == 1 && rec.calls[0].0 === memory && rec.calls[0].1 && !f.holdsMemory && rec.activations == 1,
              "F1-hold", "setup closed (later): the memory window shows, nothing vanishes; no activation of its own")
        rec = freshFocus()
        f.holdMemoryAtLaunch(); f.memoryWindowAppeared(memory); f.setupShown(setup, page: .apps, unfinished: true)
        f.setupFinished()
        check(rec.calls.count == 1 && rec.calls[0].0 === memory && f.activations == ["memory"], "F1-hold", "setup finished: the memory window shows, in front")
        rec = freshFocus()
        f.holdMemoryAtLaunch(); f.memoryWindowAppeared(memory); f.setupShown(setup, page: .permissions, unfinished: true)
        f.quitting = true
        f.setupClosed()
        check(rec.calls.isEmpty && f.holdsMemory, "F1-hold", "setup closing because DayDream quits: nothing shows")
        rec = freshFocus()
        check(!f.revealMemory(activate: true) && rec.calls.isEmpty && !f.reopenFromDock(), "F1-hold", "nothing held: nothing to reveal; the Dock does what it always did")
        rec = freshFocus()
        f.holdMemoryAtLaunch(); f.memoryWindowAppeared(memory)
        check(f.reopenFromDock() && rec.calls.count == 1 && rec.calls[0].0 === memory, "F1-hold", "the Dock with no setup open: the held memory window shows")
        check(SetupFocus.noWindowOpen([memory, setup]), "F1-hold", "hidden windows don't count as open")
        // F1b (review 10/9): Open DayDream in the menu bar panel or the app menu, as the Dock: setup in front while it is
        // open and unfinished, never the held memory window over it.
        rec = freshFocus()
        f.holdMemoryAtLaunch(); f.memoryWindowAppeared(memory); f.setupShown(setup, page: .permissions, unfinished: true)
        check(f.reopen("menu_bar") && rec.calls.count == 1 && rec.calls[0].0 === setup && rec.calls[0].1 && f.activations == ["menu_bar"] && f.holdsMemory,
              "F1b-menu", "Open DayDream while setup is unfinished: setup comes forward, key; the memory window stays held (\(f.activations))")
        rec = freshFocus()
        f.holdMemoryAtLaunch(); f.memoryWindowAppeared(memory)
        check(f.reopen("menu_bar") && rec.calls.count == 1 && rec.calls[0].0 === memory && !f.holdsMemory, "F1b-menu", "with no setup open: the held memory window shows")
        let commandsSource = source("Sources/MacMemApp/AppCommands.swift")
        let show = body(of: "static func show(_ openWindow: OpenWindowAction)", in: commandsSource)
        check(show.contains("if SetupFocus.shared.reopen(\"menu_bar\") { return }") && !show.contains("revealMemory("),
              "F1b-menu", "sources: the menu bar's and the app menu's Open DayDream go through the same rule as the Dock")

        // F2 prepareFocus at launch
        rec = freshFocus()
        let d = MemoryDefaults()
        SetupRelaunchContext(reason: .setup, page: 1, frame: [10, 10, 660, 560], screen: nil, recording: true, savedAt: Date().timeIntervalSince1970).save(d)
        d.set(true, forKey: MemoryViewModel.setupCompletedKey)
        MemoryViewModel.relaunchWantsRecording = false
        DaydreamLaunchSession.prepareFocus(d)
        check(f.relaunch?.reason == .setup && f.holdsMemory && MemoryViewModel.relaunchWantsRecording && d.object(forKey: SetupRelaunchContext.key) == nil,
              "F2-launch", "a relaunch: its context is read (and removed), the memory window is held, recording is wanted")
        rec = freshFocus(); MemoryViewModel.relaunchWantsRecording = false
        DaydreamLaunchSession.prepareFocus(d)
        check(f.relaunch == nil && !f.holdsMemory && !MemoryViewModel.relaunchWantsRecording, "F2-launch", "an ordinary launch after setup: nothing held, nothing wanted")
        rec = freshFocus()
        DaydreamLaunchSession.prepareFocus(MemoryDefaults())
        check(f.relaunch == nil && f.holdsMemory, "F2-launch", "a first setup: the memory window is held (setup is the only window)")
        rec = freshFocus()
        SetupRelaunchContext(reason: .background, page: nil, frame: nil, screen: nil, recording: true, savedAt: Date().timeIntervalSince1970).save(d)
        DaydreamLaunchSession.prepareFocus(d)
        check(f.quietLaunch && f.holdsMemory && MemoryViewModel.relaunchWantsRecording, "F2-launch", "a background restart: quiet (no window), recording wanted")
        rec = freshFocus(); MemoryViewModel.relaunchWantsRecording = false
        SetupRelaunchContext(reason: .window, page: nil, frame: nil, screen: nil, recording: true, savedAt: Date().timeIntervalSince1970).save(d)
        DaydreamLaunchSession.prepareFocus(d)
        check(!f.quietLaunch && !f.holdsMemory && MemoryViewModel.relaunchWantsRecording && f.takeRelaunchPage() == nil, "F2-launch",
              "a restart from the permissions window (setup finished): an ordinary launch that records again")
        MemoryViewModel.relaunchWantsRecording = false

        // F3 a relaunch's setup: where it was, on its page, key and in front, once
        let screen = NSScreen.screens.first.map { ($0.frame, $0.visibleFrame) } ?? (CGRect(x: 0, y: 0, width: 1440, height: 900), CGRect(x: 0, y: 0, width: 1440, height: 875))
        let saved = CGRect(x: screen.1.minX + 37, y: screen.1.minY + 41, width: 660, height: 560)
        rec = freshFocus()
        f.relaunch = SetupRelaunchContext(reason: .setup, page: DaydreamOnboardingPage.review.rawValue, frame: SetupRelaunchContext.values(saved),
                                          screen: SetupRelaunchContext.values(screen.0), recording: false, savedAt: Date().timeIntervalSince1970)
        let o = try await open("relaunch-setup")
        o.model.chromeAccessEnvironment.installed = { false }   // no Chrome row holding Permissions
        DaydreamOnboarding.drawnForChecks = nil
        let window = host(DaydreamOnboarding(model: o.model))
        _ = try await waitFor(3) { DaydreamOnboarding.drawnForChecks?.page == .review }
        check(f.activations == ["relaunch"] && rec.activations == 1 && rec.calls.count == 1 && rec.calls.first?.1 == true && rec.calls.first?.0 === window,
              "F3-relaunch", "setup after DayDream's relaunch: one activation, setup's own window key and in front: \(f.activations)")
        check(window.frame.origin == saved.origin, "F3-relaunch", "…where it was: \(window.frame.origin) (saved \(saved.origin))")
        check(DaydreamOnboarding.drawnForChecks?.page == .review, "F3-relaunch", "…on the page it was on (Permissions moves on by itself): \(String(describing: DaydreamOnboarding.drawnForChecks?.page))")
        check(!window.isVisible, "F3-relaunch", "the hosting window was never shown")
        f.placeAfterRelaunch(window)
        check(f.activations == ["relaunch"] && f.takeRelaunchPage() == nil, "F3-relaunch", "once: setup appearing again changes nothing")
        window.contentView = nil
        try await tick(0.05)
        rec = freshFocus()
        let plain = host(DaydreamOnboarding(model: o.model))
        try await tick(0.5)
        check(f.activations.isEmpty && rec.calls.isEmpty && f.setupWindow === plain, "F3-relaunch", "setup opened any other way: no activation of its own")
        plain.contentView = nil
        try await close(o)

        // F4 the hand-back
        rec = freshFocus()
        f.setupShown(setup, page: .permissions, unfinished: true)
        var front = true, sheet: Bool? = false, auth = false
        f.settingsFrontmost = { front }; f.settingsSheetUp = { sheet }; f.authOnScreen = { auth }
        check(f.handBack("accessibility", needsReopen: false) && f.activations == ["handBack.accessibility"] && rec.calls.count == 1 && rec.calls[0].1,
              "F4-handback", "a permission turned on beside setup (System Settings in front, no sheet): setup comes back, key")
        check(!f.handBack("accessibility", needsReopen: false) && rec.calls.count == 1, "F4-handback", "…once per permission")
        check(!f.handBack("inputMonitoring", needsReopen: true), "F4-handback", "never when it needs DayDream to reopen (macOS's sheet; the restart brings setup)")
        sheet = true
        check(!f.handBack("inputMonitoring", needsReopen: false), "F4-handback", "never while System Settings shows a sheet")
        sheet = nil
        check(!f.handBack("inputMonitoring", needsReopen: false), "F4-handback", "never when the sheet can't be read")
        sheet = false; auth = true
        check(!f.handBack("inputMonitoring", needsReopen: false), "F4-handback", "never over a password window")
        auth = false; front = false
        check(!f.handBack("inputMonitoring", needsReopen: false), "F4-handback", "never when System Settings isn't in front")
        front = true
        check(f.handBack("inputMonitoring", needsReopen: false) && rec.calls.count == 2, "F4-handback", "the other permission, once it may")

        // F4c (review 10/9): the read that turned a permission Allowed came while the password window was still closing:
        // the hand-back waits for it to clear (while the permission still reads Allowed), instead of never coming.
        rec = freshFocus()
        f.setupShown(setup, page: .permissions, unfinished: true)
        var authUp = true, allowedNow = true, frontNow = true
        f.settingsFrontmost = { frontNow }; f.settingsSheetUp = { false }; f.authOnScreen = { authUp }
        check(!f.handBack("accessibility", needsReopen: false, stillAllowed: { allowedNow }) && rec.calls.isEmpty, "F4c-retry",
              "Allowed while the password window is still on screen: nothing comes forward yet")
        try await tick(0.4)
        check(rec.calls.isEmpty, "F4c-retry", "…still nothing while it stays")
        authUp = false
        _ = try await waitFor(1) { !rec.calls.isEmpty }
        check(rec.calls.count == 1 && rec.calls[0].0 === setup && rec.calls[0].1 && f.activations == ["handBack.accessibility"], "F4c-retry",
              "the password window goes: setup comes forward, key, once (\(f.activations))")
        try await tick(0.3)
        check(rec.calls.count == 1, "F4c-retry", "…and only once")
        rec = freshFocus()
        f.setupShown(setup, page: .permissions, unfinished: true)
        frontNow = false
        f.settingsFrontmost = { frontNow }; f.settingsSheetUp = { false }; f.authOnScreen = { false }
        _ = f.handBack("inputMonitoring", needsReopen: false, stillAllowed: { allowedNow })
        allowedNow = false
        try await tick(0.25)
        frontNow = true
        try await tick(0.4)
        check(rec.calls.isEmpty, "F4c-retry", "the permission reads off again before it may: no hand-back")
        rec = freshFocus()
        f.setupShown(setup, page: .permissions, unfinished: true)
        frontNow = false; allowedNow = true
        f.settingsFrontmost = { frontNow }; f.settingsSheetUp = { false }; f.authOnScreen = { false }
        _ = f.handBack("inputMonitoring", needsReopen: false, stillAllowed: { allowedNow }, retryFor: 0.4)
        try await tick(0.7)
        frontNow = true
        try await tick(0.4)
        check(rec.calls.isEmpty, "F4c-retry", "held back longer than its wait (5 s; 0.4 s here): it gives up")
        let onboardingSource = source("Sources/MacMemApp/DaydreamOnboarding.swift")
        check(onboardingSource.contains("SetupFocus.shared.handBack(\"accessibility\", needsReopen: reopen, stillAllowed: { Self.readPermissions().accessibility })")
              && onboardingSource.contains("SetupFocus.shared.handBack(\"inputMonitoring\", needsReopen: reopen, stillAllowed: { Self.readPermissions().inputMonitoring })"),
              "F4c-retry", "sources: setup's hand-back reads the permission again while it waits")

        // F4b after setup, the permissions window ("Turn on…", B9) is handed back to, as setup is (integration of A and B:
        // the drag guide's celebration no longer activates anything)
        rec = freshFocus()
        let perms = hiddenWindow()
        f.settingsFrontmost = { true }; f.settingsSheetUp = { false }; f.authOnScreen = { false }
        f.permissionsWindowShowing = 1; f.permissionsWindow = perms
        let axOff = PermissionSnapshot(accessibility: false, inputMonitoring: true), bothOn = PermissionSnapshot(accessibility: true, inputMonitoring: true)
        f.permissionsWindowRead(from: axOff, to: bothOn, needsReopen: false)
        _ = try await waitFor(0.5) { !rec.calls.isEmpty }
        check(f.activations == ["handBack.window.accessibility"] && rec.activations == 1 && rec.calls.count == 1 && rec.calls[0].0 === perms && rec.calls[0].1,
              "F4b-window", "Accessibility turned on from the permissions window: that window comes back, key: \(f.activations)")
        f.permissionsWindowRead(from: axOff, to: bothOn, needsReopen: false)
        try await tick(0.1)
        check(rec.calls.count == 1, "F4b-window", "…once")
        rec = freshFocus()
        f.settingsFrontmost = { true }; f.settingsSheetUp = { false }; f.authOnScreen = { false }
        f.permissionsWindowShowing = 1; f.permissionsWindow = perms
        f.permissionsWindowRead(from: PermissionSnapshot(accessibility: true, inputMonitoring: false), to: bothOn, needsReopen: false)
        f.permissionsWindowRead(from: axOff, to: bothOn, needsReopen: true)
        f.permissionsWindowRead(from: PermissionSnapshot(), to: bothOn, needsReopen: false)
        try await tick(0.1)
        check(rec.calls.isEmpty && f.activations.isEmpty, "F4b-window",
              "never for Input Monitoring (macOS's Quit & Reopen sheet), a needed reopen, or a first read")
        f.settingsSheetUp = { true }
        f.permissionsWindowRead(from: axOff, to: bothOn, needsReopen: false)
        f.settingsSheetUp = { false }; f.permissionsWindowShowing = 0
        f.permissionsWindowRead(from: axOff, to: bothOn, needsReopen: false)
        try await tick(0.1)
        check(rec.calls.isEmpty, "F4b-window", "never under a sheet, nor once the permissions window has closed")
        f.permissionsWindowShowing = 1; f.setupShown(setup, page: .permissions, unfinished: true)
        f.permissionsWindowRead(from: axOff, to: bothOn, needsReopen: false)
        _ = try await waitFor(0.5) { !rec.calls.isEmpty }
        check(rec.calls.count == 1 && rec.calls[0].0 === setup && f.activations == ["handBack.accessibility"], "F4b-window",
              "with setup open too, setup is the one handed back to (rule 3)")
        let appSource = source("Sources/MacMemApp/MacMemApp.swift"), windowFocus = body(of: "struct PermissionsWindowFocus", in: appSource)
        check(appSource.contains("PermissionsWindowFocus(model:model) {\n                    PermissionRequestsHost(model:model) {\n                        DaydreamPermissionSettings(")
              && windowFocus.contains("SetupFocus.shared.permissionsWindowRead(from:old,to:now,needsReopen:reopen,stillAllowed:{ Self.read().accessibility == true })")
              && windowFocus.contains("SetupFocus.shared.permissionsWindow=$0"),
              "F4b-window", "the permissions window reads its permissions and is handed back to")

        // F5 nothing activates during a press; a read waits for mouse-up
        rec = freshFocus()
        f.setupShown(setup, page: .permissions, unfinished: true)
        var down = true
        f.mouseDown = { down }
        f.bringSetupForward("test")
        try await tick(0.3)
        check(f.activations.isEmpty && rec.calls.isEmpty, "F5-press", "while the button is down, nothing comes forward")
        down = false
        _ = try await waitFor(0.5) { !f.activations.isEmpty }
        check(f.activations == ["test"] && rec.calls.count == 1, "F5-press", "…then setup comes forward once it is up")
        rec = freshFocus(); f.setupShown(setup, page: .permissions, unfinished: true)
        f.mouseDown = { true }
        f.bringSetupForward("held", maxWait: 0.3)
        try await tick(0.6)
        check(f.activations.isEmpty, "F5-press", "a press that never ends: it gives up rather than activate under it")
        rec = freshFocus(); f.setupShown(setup, page: .permissions, unfinished: true)
        f.chromeAsking = { true }
        f.bringSetupForward("chrome", maxWait: 0.3)
        try await tick(0.5)
        check(f.activations.isEmpty, "F5-press", "never while Chrome's question is up")
        rec = freshFocus()
        var ran: Date?
        down = true; f.mouseDown = { down }
        let t0 = Date()
        f.afterMouseUp { ran = Date() }
        try await tick(0.12); down = false
        _ = try await waitFor(0.5) { ran != nil }
        let waited = ran.map { $0.timeIntervalSince(t0) } ?? -1
        check(waited >= 0.1 && waited < 0.25, "F5-press", "a read started while the button is down runs once it is up: \(Int(waited * 1000)) ms")
        ran = nil; down = true
        let t1 = Date()
        f.afterMouseUp { ran = Date() }
        _ = try await waitFor(0.8) { ran != nil }
        let capped = ran.map { $0.timeIntervalSince(t1) } ?? -1
        check(capped >= 0.28 && capped < 0.5, "F5-press", "…or after 300 ms at most: \(Int(capped * 1000)) ms")
        ran = nil; down = false
        f.afterMouseUp { ran = Date() }
        check(ran != nil, "F5-press", "no press: at once")
        _ = freshFocus()
    }

    // MARK: M. The real model

    /// M1: System Settings shows its sheet: the restart waits; setup says Restarting…, disabled, Chrome's Allow too; Later
    /// (the sheet goes): the restart goes at once. Its context was saved first.
    static func restartWaitsForSheet() async throws {
        Seams.reset(); Seams.sheet = true
        let rec = freshFocus()
        let setup = hiddenWindow(NSRect(x: 120, y: 140, width: 660, height: 560))
        SetupFocus.shared.setupShown(setup, page: .permissions, unfinished: true)
        let o = try await decidedRestart("restart-sheet")
        check(o.model.permissionAutoRelaunch && o.model.permissionRequests?.autoRelaunch == true, "M1-sheet", "both on: the restart is decided, the page says so")
        let context = (MemoryViewModel.autoRelaunchDefaults.object(forKey: SetupRelaunchContext.key) as? Data).flatMap { try? JSONDecoder().decode(SetupRelaunchContext.self, from: $0) }
        check(context?.reason == .setup && context?.setupPage == .permissions && context?.setupFrame == setup.frame, "M1-sheet",
              "its context is saved as it is decided (macOS's own Quit & Reopen may come first): \(String(describing: context))")
        MemoryViewModel.restartContextRefresh = 1
        defer { MemoryViewModel.restartContextRefresh = 20 }
        try await tick(3.0)
        check(Seams.restarts == 0 && o.model.permissionAutoRelaunch, "M1-sheet", "the sheet stays 3 s: no restart under it (\(Seams.restarts))")
        let later = (MemoryViewModel.autoRelaunchDefaults.object(forKey: SetupRelaunchContext.key) as? Data).flatMap { try? JSONDecoder().decode(SetupRelaunchContext.self, from: $0) }
        check(later?.reason == .setup && (later?.savedAt ?? 0) >= (context?.savedAt ?? .infinity) + 1.5, "M1-sheet",
              "while it waits, the context is saved again (macOS's Quit & Reopen minutes later still finds a fresh one): \(String(format: "%.1f", (later?.savedAt ?? 0) - (context?.savedAt ?? 0))) s newer")
        // Setup while it waits
        DaydreamOnboarding.drawnForChecks = nil
        let window = host(DaydreamOnboarding(model: o.model))
        _ = try await waitFor(6) { DaydreamOnboarding.drawnForChecks?.chromeRow != nil }
        let drawn = DaydreamOnboarding.drawnForChecks
        check(drawn?.button == "Restarting…" && drawn?.canContinue == false, "M1-sheet",
              "setup's button says Restarting…, disabled: \(String(describing: drawn?.button)) \(String(describing: drawn?.canContinue))")
        check(drawn?.chromeRow?.disabled == true, "M1-sheet", "Chrome's Allow is disabled: \(String(describing: drawn?.chromeRow?.disabled))")
        drawn?.chromeRow?.allow()
        o.model.askChromeAccessInSetup()
        o.model.askChromeAgain()
        check(o.chrome.asks == 0 && o.chrome.opens == 0, "M1-sheet", "…and pressing it anyway asks nothing, opens nothing (asks \(o.chrome.asks), opens \(o.chrome.opens))")
        window.contentView = nil
        Seams.sheet = false
        _ = try await waitFor(1) { Seams.restarts > 0 }
        check(Seams.restarts == 1, "M1-sheet", "the sheet goes (Later): the restart goes at once (\(Seams.restarts))")
        check(rec.activations == 0, "M1-sheet", "the restart itself activates nothing")
        try await close(o)
        _ = freshFocus()
    }
    /// M2: no sheet is ever seen (macOS's alert is its privacy extension's, which System Settings' windows may not hold;
    /// review 10/9): the restart goes after about 10 s, never at 1.5 s while the alert may still be up. (An unreadable
    /// sheet, nil, waits the same: R3-gate.)
    static func restartUnreadableSheet() async throws {
        Seams.reset(); Seams.sheet = false
        _ = freshFocus()
        let o = try await decidedRestart("restart-unreadable")
        let t0 = Date()
        try await tick(8.5)
        check(Seams.restarts == 0 && o.model.permissionAutoRelaunch, "M2-unseen", "no sheet seen: no restart in the first 8.5 s (\(Seams.restarts))")
        _ = try await waitFor(3) { Seams.restarts > 0 }
        let after = Date().timeIntervalSince(t0)
        check(Seams.restarts == 1 && after >= 9.5 && after < 11, "M2-unseen", "…then it goes, \(String(format: "%.1f", after)) s after it was decided")
        try await close(o)
    }
    /// M3: a press and a drag (a card) hold the restart; it goes once they end.
    static func restartWaitsForPress() async throws {
        Seams.reset(); Seams.pressing = true
        _ = freshFocus()
        let o = try await decidedRestart("restart-press")
        Seams.flashSheet()   // macOS's sheet came and went (Later): only the press holds it now
        try await tick(2.5)
        check(Seams.restarts == 0, "M3-press", "the button is down: no restart (\(Seams.restarts))")
        Seams.pressing = false; Seams.dragging = true
        try await tick(1.0)
        check(Seams.restarts == 0, "M3-press", "a card drag runs: no restart (\(Seams.restarts))")
        Seams.dragging = false
        _ = try await waitFor(1) { Seams.restarts > 0 }
        check(Seams.restarts == 1, "M3-press", "both over: the restart goes (\(Seams.restarts))")
        try await close(o)
    }
    /// M4: Chrome's question in flight (Allow pressed with Chrome closed: it opens in the background to ask) holds the
    /// restart until it is answered.
    static func restartWaitsForChrome() async throws {
        Seams.reset()
        _ = freshFocus()
        let p = try await decidedRestartWithChrome("restart-chrome")
        Seams.flashSheet()
        try await tick(2.5)
        check(p.chrome.opens == 1 && p.model.chromeQuestionInFlight && Seams.restarts == 0, "M4-chrome",
              "Chrome's question in flight: no restart (opens \(p.chrome.opens), in flight \(p.model.chromeQuestionInFlight), restarts \(Seams.restarts))")
        p.chrome.heldOpen?(false)
        _ = try await waitFor(1.5) { Seams.restarts > 0 }
        check(!p.model.chromeQuestionInFlight && Seams.restarts == 1, "M4-chrome", "answered: the restart goes (\(Seams.restarts))")
        try await close(p)
    }
    /// Allow pressed (Chrome closed: it opens in the background to ask) just before Input Monitoring reads on.
    static func decidedRestartWithChrome(_ name: String) async throws -> Opened {
        MemoryViewModel.autoRelaunchDefaults = MemoryDefaults()
        Seams.restarts = 0
        Seams.granted = false
        let t0 = Date()
        let o = try await open(name, settle: false)
        while Date() < t0.addingTimeInterval(2.4) { try await tick(0.05) }
        o.model.askChromeAccessInSetup()
        Seams.granted = true
        o.model.refreshCaptureStatus()
        return o
    }
    /// M5: the restart was asked for and DayDream is still running 5 s later: its helper ends, the line goes, Start offers
    /// Quit & Reopen, and no second restart follows.
    static func restartStillAlive() async throws {
        Seams.reset()
        _ = freshFocus()
        let setup = hiddenWindow()
        SetupFocus.shared.setupShown(setup, page: .permissions, unfinished: true)
        let o = try await decidedRestart("restart-alive")
        Seams.flashSheet()
        _ = try await waitFor(2.5) { Seams.restarts > 0 }
        check(Seams.restarts == 1 && o.model.permissionAutoRelaunch, "M5-alive", "the restart was asked for (\(Seams.restarts))")
        try await tick(4.0)
        check(o.model.permissionAutoRelaunch && Seams.helperCancels == 0, "M5-alive", "4 s on, still waiting for the quit")
        _ = try await waitFor(2.0) { !o.model.permissionAutoRelaunch }
        check(!o.model.permissionAutoRelaunch && Seams.helperCancels == 1 && o.model.setupStepForStart() == .permissions
              && MemoryViewModel.autoRelaunchDefaults.object(forKey: SetupRelaunchContext.key) == nil && !SetupFocus.shared.quitting,
              "M5-alive", "still running after 5 s: the helper ends, the line goes, Start offers Quit & Reopen, the context goes (cancels \(Seams.helperCancels))")
        o.model.refreshCaptureStatus(); try await tick(2.0)
        check(Seams.restarts == 1, "M5-alive", "…and it never restarts again by itself (\(Seams.restarts))")
        // A helper that couldn't start at all: the same, at once.
        Seams.reset(); Seams.restartWorks = false
        let q = try await decidedRestart("restart-nohelper")
        Seams.flashSheet()
        _ = try await waitFor(2.5) { Seams.restarts > 0 }
        try await tick(0.1)
        check(Seams.restarts == 1 && !q.model.permissionAutoRelaunch && q.model.setupStepForStart() == .permissions, "M5-alive",
              "a helper that couldn't start: no restart line, Quit & Reopen")
        try await close(o); try await close(q)
        _ = freshFocus()
    }
    /// M6: at most 2 restarts in 30 minutes; never under the person's open window.
    static func restartBudgetAndWindows() async throws {
        Seams.reset()
        let o = try await decidedRestart("restart-budget") {
            SelfRestartBudget.note(MemoryViewModel.autoRelaunchDefaults, now: Date().addingTimeInterval(-900))
            SelfRestartBudget.note(MemoryViewModel.autoRelaunchDefaults, now: Date().addingTimeInterval(-300))
        }
        try await tick(2.0)
        check(!o.model.permissionAutoRelaunch && Seams.restarts == 0 && o.model.setupStepForStart() == .permissions, "M6-budget",
              "two restarts in the last 30 minutes: no third; Quit & Reopen (\(Seams.restarts))")
        try await close(o)
        Seams.reset(); Seams.windowsAllow = false
        let p = try await decidedRestart("restart-window")
        try await tick(2.0)
        check(!p.model.permissionAutoRelaunch && Seams.restarts == 0, "M6-window", "the person's own window is open (no permission page): no restart (\(Seams.restarts))")
        try await close(p)
        // Any quit while setup is open and unfinished saves the context (macOS's own Quit & Reopen).
        Seams.reset()
        _ = freshFocus()
        let q = try await open("quit-context")
        MemoryViewModel.autoRelaunchDefaults = MemoryDefaults()
        let setup = hiddenWindow(NSRect(x: 33, y: 44, width: 660, height: 560))
        SetupFocus.shared.setupShown(setup, page: .permissions, unfinished: true)
        AppQuit.willQuit()
        let saved = (MemoryViewModel.autoRelaunchDefaults.object(forKey: SetupRelaunchContext.key) as? Data).flatMap { try? JSONDecoder().decode(SetupRelaunchContext.self, from: $0) }
        check(saved?.reason == .setup && saved?.setupPage == .permissions && saved?.setupFrame == setup.frame && SetupFocus.shared.quitting, "M6-quit",
              "a quit while setup is open (macOS's Quit & Reopen): the context is saved, so setup comes back in front: \(String(describing: saved))")
        _ = freshFocus()
        MemoryViewModel.autoRelaunchDefaults = MemoryDefaults()
        AppQuit.willQuit()
        check(MemoryViewModel.autoRelaunchDefaults.object(forKey: SetupRelaunchContext.key) == nil, "M6-quit", "a quit with no setup open saves nothing")
        try await close(q)
        _ = freshFocus()
    }
    /// M7: no key reaches the tap while recording: DayDream restarts in the background (open -g, no window next time);
    /// still running 5 s later, recording stops with its reason.
    static func keysNotArriving() async throws {
        Seams.reset()
        _ = freshFocus()
        MemoryViewModel.autoRelaunchDefaults = MemoryDefaults()
        let o = try await open("keys")
        o.model.startCapture()
        try await tick(0.4)
        guard o.model.recording, let capture = Seams.lastCapture as? EventCapture else { check(false, "M7-keys", "harness: the model did not record"); return }
        capture.onKeysNotArriving?()
        try await tick(0.1)
        let context = (MemoryViewModel.autoRelaunchDefaults.object(forKey: SetupRelaunchContext.key) as? Data).flatMap { try? JSONDecoder().decode(SetupRelaunchContext.self, from: $0) }
        check(Seams.backgroundRestarts == 1 && Seams.restarts == 0, "M7-keys",
              "keys not arriving: the background restart (open -g), never the one that shows setup (\(Seams.backgroundRestarts), \(Seams.restarts))")
        check(context?.reason == .background && context?.recording == true, "M7-keys", "…its context: no window, recording wanted: \(String(describing: context))")
        _ = try await waitFor(6) { !o.model.recording }
        check(!o.model.recording && Seams.helperCancels == 1, "M7-keys",
              "still running after 5 s: the helper ends and recording stops with its reason (recording \(o.model.recording), cancels \(Seams.helperCancels), pending \(o.model.permissionAutoRelaunch), \(o.model.recordingState))")
        try await close(o)
    }
    /// M8: recording was on when a permission went off; the comeback waits; Input Monitoring needs the reopen: the launch
    /// intent keeps recording wanted the whole way, and the restart's context says so.
    static func recordingSurvivesRestart() async throws {
        Seams.reset()
        _ = freshFocus()
        MemoryViewModel.autoRelaunchDefaults = MemoryDefaults()
        let intent = MemoryDefaults()
        intent.set(["recording": true], forKey: LaunchResume.key)
        Seams.granted = false
        let o = try await open("comeback", intent: intent, settle: false)
        // The launch start gives up on the permission: recording isn't wanted by the start any more, the comeback waits.
        _ = try await waitFor(15) { !o.model.recording && !o.model.recordingWanted && o.model.recordingState.kind == .needsPermission }
        check(!o.model.recording && !o.model.recordingWanted, "harness", "comeback: the launch start gave up on the permission (wanted \(o.model.recordingWanted), \(o.model.recordingState))")
        check(intent.dictionary(forKey: LaunchResume.key)?["recording"] as? Bool == true, "M8-intent",
              "a permission stop waiting for its comeback keeps recording wanted at the next launch: \(String(describing: intent.dictionary(forKey: LaunchResume.key)))")
        // Input Monitoring on again; it needs DayDream to reopen: the comeback ends without recording, and DayDream restarts.
        Seams.granted = true
        _ = try await waitFor(4) { o.model.permissionAutoRelaunch }
        Seams.flashSheet()
        check(intent.dictionary(forKey: LaunchResume.key)?["recording"] as? Bool == true, "M8-intent",
              "Input Monitoring needs the reopen: recording is still wanted for the reopened DayDream: \(String(describing: intent.dictionary(forKey: LaunchResume.key)))")
        _ = try await waitFor(2.5) { Seams.restarts > 0 }
        let context = (MemoryViewModel.autoRelaunchDefaults.object(forKey: SetupRelaunchContext.key) as? Data).flatMap { try? JSONDecoder().decode(SetupRelaunchContext.self, from: $0) }
        check(Seams.restarts == 1, "M8-intent",
              "…and DayDream restarts itself (\(Seams.restarts); recording \(o.model.recording), pending \(o.model.permissionAutoRelaunch), step \(String(describing: o.model.setupStepForStart())), \(o.model.recordingState))")
        check(context?.recording == true, "M8-intent", "…its context says recording was wanted (the relaunch records again): \(String(describing: context))")
        try await close(o)
        // Recording, then a permission really turned off: the recorder stops, the comeback waits, recording stays wanted.
        Seams.reset()
        let intent2 = MemoryDefaults()
        let p = try await open("comeback-recording", intent: intent2)
        p.model.startCapture()
        _ = try await waitFor(1) { p.model.recording }
        check(intent2.dictionary(forKey: LaunchResume.key)?["recording"] as? Bool == true, "harness", "comeback-recording: recording saves the intent")
        Seams.granted = false
        let end = Date().addingTimeInterval(4)
        while p.model.recording, Date() < end { p.model.refreshCaptureStatus(); p.model.coordinator?.reconcileResume(); try await tick(0.25) }
        try await tick(0.5)
        check(!p.model.recording && !p.model.recordingWanted && intent2.dictionary(forKey: LaunchResume.key)?["recording"] as? Bool == true, "M8-intent",
              "recording stopped by a permission turned off: a restart meanwhile records again (\(p.model.recording), wanted \(p.model.recordingWanted), \(String(describing: intent2.dictionary(forKey: LaunchResume.key))))")
        try await close(p)
    }
    /// M9: the relaunch with recording wanted (the context's) records again with no saved intent.
    static func relaunchRecordsAgain() async throws {
        Seams.reset()
        // Models opened by earlier parts finish opening their history first (the flag is the one launch's, read once).
        try await tick(1.0)
        MemoryViewModel.relaunchWantsRecording = true
        let o = try await open("relaunch-records", intent: MemoryDefaults())
        _ = try await waitFor(10) { o.model.recording }
        check(o.model.recording && !MemoryViewModel.relaunchWantsRecording, "M9-relaunch",
              "the relaunch records again (once): recording \(o.model.recording), flag \(MemoryViewModel.relaunchWantsRecording), \(o.model.recordingState)")
        try await close(o)
        let p = try await open("relaunch-plain", intent: MemoryDefaults())
        try await tick(0.5)
        check(!p.model.recording, "M9-relaunch", "an ordinary launch with nothing wanted doesn't")
        try await close(p)
    }
    /// M10: a first setup on a fresh history forgets an earlier install's Chrome answer, card and reminder; an unfinished
    /// setup's row reads Chrome from macOS alone.
    static func firstSetupForgetsChrome() async throws {
        Seams.reset()
        let keys = [ChromeAccessMemory.answerKey, DaydreamChromeCard.shownKey, ChromeAccessMemory.reminderKey]
        UserDefaults.standard.set(false, forKey: MemoryViewModel.setupCompletedKey)
        defer { UserDefaults.standard.removeObject(forKey: MemoryViewModel.setupCompletedKey); for k in keys { UserDefaults.standard.removeObject(forKey: k) } }
        ChromeAccessMemory.save(.denied)
        UserDefaults.standard.set(true, forKey: DaydreamChromeCard.shownKey)
        UserDefaults.standard.set(true, forKey: ChromeAccessMemory.reminderKey)
        let o = try await open("fresh-setup", intent: MemoryDefaults())
        let left = keys.filter { UserDefaults.standard.object(forKey: $0) != nil }
        check(o.model.onboardingTypingChoicePending, "harness", "a fresh history: setup's choices are pending")
        check(left.isEmpty, "M10-fresh", "a first setup on a fresh history starts with no earlier Chrome answer, card or reminder: left \(left)")
        try await close(o)
        // M10b (review 10/9): DayDream's relaunch in the middle of that same setup (Chrome answered before Input
        // Monitoring's restart, Chrome closed since): the answer is this setup's, kept, and the row shows it (no Allow again).
        ChromeAccessMemory.save(.denied)
        SetupFocus.shared.relaunch = SetupRelaunchContext(reason: .setup, page: DaydreamOnboardingPage.permissions.rawValue, frame: nil, screen: nil,
                                                          recording: false, savedAt: Date().timeIntervalSince1970)
        let r = try await open("relaunch-setup", intent: MemoryDefaults())
        SetupFocus.shared.relaunch = nil
        check(r.model.onboardingTypingChoicePending, "harness", "relaunch: setup's choices are still pending")
        check(ChromeAccessMemory.saved() == .denied && r.model.chromeAnsweredThisLaunch
              && r.model.chromeRowAccess(lastAnswer: r.model.chromeAnsweredThisLaunch) == .denied, "M10b-relaunch",
              "the relaunch keeps the answer given earlier in this setup, and the row reads it with Chrome closed: \(r.model.chromeRowAccess(lastAnswer: r.model.chromeAnsweredThisLaunch))")
        try await close(r)
        UserDefaults.standard.set(true, forKey: MemoryViewModel.setupCompletedKey)
        ChromeAccessMemory.save(.denied)
        let q = try await open("finished-setup", intent: MemoryDefaults())
        try await tick(0.3)
        check(q.model.chromeRowAccess == .denied, "M10-fresh",
              "after setup, the saved refusal holds while Chrome is closed (nothing forgot it): \(q.model.chromeRowAccess)")
        check(q.model.chromeRowAccess(lastAnswer: false) != .denied, "M10-fresh",
              "an unfinished setup's row reads macOS alone, never the saved refusal: \(q.model.chromeRowAccess(lastAnswer: false))")
        try await close(q)
    }
    /// M11: setup's lines under the cards (System Settings older than this copy, with Quit; the reopen line in the
    /// cooldown), and a permission read during a press applied only after it.
    static func setupLinesAndDeferral() async throws {
        Seams.reset()
        _ = freshFocus()
        var quits = 0
        let quit = DaydreamOnboarding.quitSystemSettings, launched = DaydreamOnboarding.settingsLaunchDate, dates = DaydreamOnboarding.bundleDates
        defer { DaydreamOnboarding.quitSystemSettings = quit; DaydreamOnboarding.settingsLaunchDate = launched; DaydreamOnboarding.bundleDates = dates }
        DaydreamOnboarding.quitSystemSettings = { quits += 1 }
        DaydreamOnboarding.settingsLaunchDate = { Date().addingTimeInterval(-3600) }
        DaydreamOnboarding.bundleDates = { [nil, Date().addingTimeInterval(-60)] }
        Seams.granted = false
        let o = try await open("setup-lines")
        DaydreamOnboarding.drawnForChecks = nil
        var window = host(DaydreamOnboarding(model: o.model))
        _ = try await waitFor(2) { DaydreamOnboarding.drawnForChecks?.settingsLine != nil }
        let drawn = DaydreamOnboarding.drawnForChecks
        check(drawn?.page == .permissions && drawn?.settingsLine == "Quit System Settings and open it again.", "M11-settings",
              "System Settings opened before this copy: the line under the cards: \(String(describing: drawn?.settingsLine))")
        drawn?.quitSettings?()
        check(quits == 1, "M11-settings", "its Quit quits System Settings, from the press only (\(quits))")
        window.contentView = nil
        DaydreamOnboarding.settingsLaunchDate = { Date() }
        DaydreamOnboarding.drawnForChecks = nil
        window = host(DaydreamOnboarding(model: o.model))
        _ = try await waitFor(1) { DaydreamOnboarding.drawnForChecks?.page == .permissions }
        try await tick(0.3)
        check(DaydreamOnboarding.drawnForChecks?.settingsLine == nil && quits == 1, "M11-settings", "System Settings opened after it: no line")
        window.contentView = nil
        try await close(o)

        // A permission read during a press: applied once it is up (300 ms at most).
        Seams.granted = true
        let p = try await open("setup-press")
        p.model.chromeAccessEnvironment.installed = { false }   // no Chrome row holding Permissions
        var readsOff = true
        let read = DaydreamOnboarding.readPermissions
        defer { DaydreamOnboarding.readPermissions = read }
        DaydreamOnboarding.readPermissions = { readsOff ? (false, false) : (true, true) }
        var asked: [Date] = []
        var flipped = Date.distantFuture
        SetupFocus.shared.mouseDown = { if Date() >= flipped { asked.append(Date()) }; return true }
        DaydreamOnboarding.drawnForChecks = nil
        window = host(DaydreamOnboarding(model: p.model))
        _ = try await waitFor(2) { DaydreamOnboarding.drawnForChecks?.page == .permissions }
        try await tick(0.3)
        flipped = Date(); readsOff = false
        _ = try await waitFor(4) { DaydreamOnboarding.drawnForChecks?.page == .apps }
        let moved = Date()
        let first = asked.first
        let delay = first.map { moved.timeIntervalSince($0) } ?? -1
        check(DaydreamOnboarding.drawnForChecks?.page == .apps && first != nil && delay >= 0.25 && delay < 0.8, "M11-press",
              "both turned on while the button is down: the page moves on to Apps only after the press (300 ms at most): \(Int(delay * 1000)) ms")
        window.contentView = nil
        try await close(p)
        _ = freshFocus()
    }

    /// M12 (review 10/9, B9): Settings › Permissions is a sheet that keeps nothing beside System Settings: its card press
    /// closes the sheet and opens the small permissions window on that permission; Allow Permissions with no permission
    /// named after setup opens that window too, never Settings' sheet.
    static func settingsHandsToPermissionsWindow() async throws {
        Seams.reset()
        _ = freshFocus()
        let o = try await open("settings-route")
        var opens = 0
        o.model.openPermissionsWindow = { opens += 1 }
        o.model.settingsSection = "Permissions"; o.model.settingsPresented = true
        let route = o.model.permissionRequests?.openInWindow
        check(route != nil, "M12-settings", "Settings' permission page gets a route to the permissions window")
        route?("accessibility")
        check(opens == 1 && !o.model.settingsPresented && o.model.permissionPaneRequest == .accessibility, "M12-settings",
              "its card's Open System Settings: the sheet closes, the permissions window opens on Accessibility (opens \(opens), sheet \(o.model.settingsPresented), \(String(describing: o.model.permissionPaneRequest)))")
        o.model.permissionPaneRequest = nil; o.model.settingsPresented = false
        var mains = 0
        o.model.showPermissionCards(nil, openSetup: {}, openMain: { mains += 1 })
        check(opens == 2 && mains == 0 && !o.model.settingsPresented, "M12-settings",
              "Allow Permissions after setup, no permission named: the permissions window, not Settings' sheet (opens \(opens), main \(mains), sheet \(o.model.settingsPresented))")
        o.model.openPermissionsWindow = nil
        check(o.model.permissionRequests?.openInWindow == nil, "M12-settings", "no permissions window to open (no memory window yet): the page opens System Settings itself")
        o.model.showPermissionCards(nil, openSetup: {}, openMain: { mains += 1 })
        check(mains == 1 && o.model.settingsPresented && o.model.settingsSection == "Permissions", "M12-settings", "…and Allow Permissions falls back to Settings › Permissions")
        o.model.settingsPresented = false
        try await close(o)
    }
    /// M13 (review 10/9, FIX-PLAN A4): recording stopped by a permission turned off; it stays off past the 10-minute
    /// comeback; the launch intent still wants recording, so turning it on (which needs a reopen) and relaunching records
    /// again. The person's own Stop ends that.
    static func recordingSurvivesComebackExpiry() async throws {
        Seams.reset()
        _ = freshFocus()
        MemoryViewModel.autoRelaunchDefaults = MemoryDefaults()
        let intent = MemoryDefaults()
        let p = try await open("expiry", intent: intent)
        p.model.startCapture()
        _ = try await waitFor(1) { p.model.recording }
        Seams.granted = false
        let end = Date().addingTimeInterval(4)
        while p.model.recording, Date() < end { p.model.refreshCaptureStatus(); p.model.coordinator?.reconcileResume(); try await tick(0.25) }
        _ = try await waitFor(2) { p.model.permissionComebackWaiting }
        check(!p.model.recording && p.model.permissionComebackWaiting, "harness", "expiry: a permission stop with its comeback waiting (\(p.model.recordingState))")
        // 11 minutes later (the wake clock moved on): the comeback ends.
        p.model.wakeSystem = WakeSystem(screenLocked: { false }, onConsole: { true },
                                        after: { delay, work in DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work) },
                                        now: { Date().addingTimeInterval(660) })
        _ = try await waitFor(5) { !p.model.permissionComebackWaiting }
        check(!p.model.permissionComebackWaiting && intent.dictionary(forKey: LaunchResume.key)?["recording"] as? Bool == true, "M13-expiry",
              "the 10-minute comeback ended with the permission still off: the next launch still wants recording (\(String(describing: intent.dictionary(forKey: LaunchResume.key))))")
        // DayDream quits with that intent (the copy below is what the next launch reads; closing this model is a Stop).
        let next = MemoryDefaults()
        next.set(intent.dictionary(forKey: LaunchResume.key), forKey: LaunchResume.key)
        // The person's own Stop while it waits: recording is no longer wanted, at this launch or the next.
        p.model.stopCapture()
        try await tick(0.3)
        check(intent.dictionary(forKey: LaunchResume.key)?["recording"] as? Bool != true && !p.model.wantedThroughPermissionStop, "M13-expiry",
              "the person's own Stop after a permission stop: nothing wanted at the next launch (\(String(describing: intent.dictionary(forKey: LaunchResume.key))))")
        try await close(p)
        // Input Monitoring on again an hour later; DayDream reopens: it records again.
        Seams.granted = true
        let q = try await open("expiry-relaunch", intent: next)
        _ = try await waitFor(10) { q.model.recording }
        check(q.model.recording, "M13-expiry", "the relaunch with the permission back records again: \(q.model.recordingState)")
        q.model.stopCapture()
        try await tick(0.3)
        check(next.dictionary(forKey: LaunchResume.key)?["recording"] as? Bool != true && !q.model.wantedThroughPermissionStop, "M13-expiry",
              "the person's own Stop: nothing wanted at the next launch (\(String(describing: next.dictionary(forKey: LaunchResume.key))))")
        try await close(q)
    }

    // MARK: S. Sources

    static func sources() {
        let guide = source("Sources/MemoryUI/PermissionDragGuide.swift")
        let celebrate = body(of: "func celebrate(", in: guide)
        check(!celebrate.isEmpty && !celebrate.contains("NSApp.activate") && !celebrate.contains("makeKeyAndOrderFront"), "S1-guide",
              "the drag guide's celebration activates nothing (Input Monitoring's sheet would be covered); setup's hand-back does")
        let read = source("Sources/MemoryUI/SystemSettingsRead.swift")
        let sheet = body(of: "public static func sheetUp()", in: read)
        if let trusted = sheet.range(of: "guard AXIsProcessTrusted()"), let ax = sheet.range(of: "AXUIElementCreateApplication") {
            check(trusted.lowerBound < ax.lowerBound, "S2-ax", "the sheet read asks Accessibility nothing before it is allowed")
        } else { check(false, "S2-ax", "the sheet read guards AXIsProcessTrusted() first") }
        if let alert = sheet.range(of: "if alertOnScreen() { return true }"), let trusted = sheet.range(of: "guard AXIsProcessTrusted()") {
            check(alert.lowerBound < trusted.lowerBound, "S2-alert", "the sheet read counts the window server's alert first (macOS's Quit & Reopen alert, Accessibility or not)")
        } else { check(false, "S2-alert", "the sheet read counts the window server's alert") }
        check(read.components(separatedBy: ".terminate()").count == 2 && body(of: "public static func quit()", in: read).contains(".terminate()"),
              "S2-ax", "System Settings is quit in one place only (its Quit press)")
        let report = source("Sources/MacMemApp/UsageReport.swift"), commands = source("Sources/MacMemApp/AppCommands.swift")
        check(body(of: "func applicationShouldHandleReopen(", in: report).contains("SetupFocus.shared.reopenFromDock()")
              && body(of: "static func show(_ openWindow: OpenWindowAction)", in: commands).contains("SetupFocus.shared.reopen(\"menu_bar\")"),
              "S3-open", "the Dock and Open DayDream go through the held memory window (never a second one), setup first while it is open")
        let onboarding = source("Sources/MacMemApp/DaydreamOnboarding.swift")
        check(onboarding.contains("NSApplication.didBecomeActiveNotification)) { _ in\n            SetupFocus.shared.afterMouseUp { refreshPermissions() }"),
              "S4-active", "coming to the front reads permissions only after the press that brought DayDream forward")
        let app = source("Sources/MacMemApp/MacMemApp.swift")
        check(body(of: "private func considerOnboarding()", in: app).contains("revealUnlessQuiet()")
              && app.contains(".background(WindowReader { SetupFocus.shared.memoryWindowAppeared($0) })"),
              "S5-hold", "the memory window is held from the moment it exists, and shown whenever setup doesn't open")
        let menu = source("Sources/MacMemApp/MenuBarContent.swift")
        check(menu.contains("var body: some View { LiveTestLabel(mark: Self.image(model: model)) }") && body(of: "struct LiveTestLabel", in: menu).contains("} else {\n            mark\n        }"),
              "S6-livetest", "the menu bar label is the mark alone unless this is the Live Test copy")
        // A7 without the refused-row regression (chrome-ask B2): an unfinished setup ignores only an answer saved before
        // this launch; macOS's answer in this launch (a refusal made in setup) keeps Ask again after Chrome closes.
        check(onboarding.contains("model.chromeRowAccess(lastAnswer: completed || model.chromeAnsweredThisLaunch)")
              && body(of: "private func chromeAccessAnswered(", in: app).contains("chromeAnsweredThisLaunch=true"),
              "S8-chrome", "an unfinished setup's Chrome row keeps macOS's answer from this launch, never one saved before it")
        let keys = body(of: "private func keysNotArriving()", in: app)
        check(keys.contains("performSelfRestart(background:true)") && !keys.contains("performAutoRelaunch"), "S7-keys", "keys not arriving restarts in the background only")
    }
}
