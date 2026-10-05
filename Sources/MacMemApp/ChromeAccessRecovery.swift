import AppKit
import SwiftUI
import MemoryUI
import MemoryCore

/// chromeask-1005 (owner 10/5): what DayDream remembers about Chrome access between launches, and where Fix goes.
/// macOS answers an access read only while Chrome is running, so the last answer is kept: with Chrome closed, a refusal
/// still shows as "Chrome pages aren't being saved. Ask again" until a read of a running Chrome says otherwise. Only the answer
/// is kept (allowed, not asked, refused), never a page, a site or a window.
enum ChromeAccessMemory {
    static let answerKey = "DaydreamChromeAccessLastAnswerV1"
    /// The one reminder when Chrome is used while access is refused was shown (it never shows again).
    static let reminderKey = "DaydreamChromeAccessReminderShownV1"
    /// After a Fix press, Chrome's status is read this often, for this long, until it is allowed.
    static let recoveryPeriod: TimeInterval = 2
    static let recoveryWindow: TimeInterval = 600

    /// The states that are macOS's answer (the rest say nothing about it: Chrome closed, a read running, unverified).
    static func answer(_ state: ChromeAccessState) -> ChromeAccessState? {
        switch state {
        case .allowed, .notAsked, .denied, .askFailed: return state
        case .unknown, .checking, .chromeNotRunning, .unverified, .twoCopies: return nil
        }
    }
    private static let names: [(ChromeAccessState, String)] = [(.allowed, "allowed"), (.notAsked, "notAsked"), (.denied, "denied"), (.askFailed, "askFailed")]
    static func saved(_ defaults: UserDefaults = .standard) -> ChromeAccessState? {
        guard let raw = defaults.string(forKey: answerKey) else { return nil }
        return names.first { $0.1 == raw }?.0
    }
    static func save(_ state: ChromeAccessState, _ defaults: UserDefaults = .standard) {
        guard let name = names.first(where: { $0.0 == state })?.1 else { return }
        defaults.set(name, forKey: answerKey)
    }
    static func reminded(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: reminderKey) }
    static func markReminded(_ defaults: UserDefaults = .standard) { defaults.set(true, forKey: reminderKey) }

    /// What the line's button does: refused, Ask again (`askChromeAgain`: DayDream clears its own Automation answer and
    /// macOS asks again, now); not asked yet, Fix opens the setup card with the Chrome row, whose Allow asks.
    enum Fix: Equatable { case askAgain, chromeCard }
    static func fix(lineAccess: ChromeAccessState) -> Fix {
        refused(lineAccess) ? .askAgain : .chromeCard
    }
    static func refused(_ access: ChromeAccessState) -> Bool { access == .denied || access == .askFailed }
}

/// Ask again (owner 10/5): macOS asks an app about Automation once, so after Don't Allow it never asks again. DayDream
/// clears its own answer, and only that: `tccutil reset AppleEvents com.getnorthlight.daydream`, run by the app on
/// itself (no admin, no shell), then asks again at once from the same press. It can never name another app (only
/// DayDream's own released bundle id, and only while it is the running app's) or another service (AppleEvents only:
/// never Accessibility, Input Monitoring or anything else). DayDream sends Apple Events only to Google Chrome, so this
/// clears nothing else of the person's. Where the reset can't run, the guide beside System Settings shows the switch.
enum ChromeAutomationReset {
    static let tool = "/usr/bin/tccutil"
    static let service = "AppleEvents"
    /// The command's arguments for this app, or nil when the running app isn't DayDream's own released bundle (a
    /// development or test build: Ask again shows the guide instead).
    static func arguments(ownBundleID: String?) -> [String]? {
        guard let id = ownBundleID, id == DaydreamIdentity.bundleID else { return nil }
        return ["reset", service, id]
    }
    /// The only command the live runner will run: exactly `reset AppleEvents <DayDream's id>`, while that is this app.
    static func isOwnReset(_ arguments: [String], running: String?) -> Bool {
        arguments.count == 3 && arguments[0] == "reset" && arguments[1] == service
            && arguments[2] == DaydreamIdentity.bundleID && running == DaydreamIdentity.bundleID
    }
    /// The live runner: `/usr/bin/tccutil` with those three arguments (no shell), waited for up to 5 s. Anything else
    /// is refused before a process starts. Returns the exit status (negative: refused, couldn't start, or timed out).
    static func runLive(_ arguments: [String]) -> Int32 {
        guard isOwnReset(arguments, running: Bundle.main.bundleIdentifier) else { return -3 }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return -1 }
        let deadline = Date().addingTimeInterval(5)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate(); return -2 }
        return process.terminationStatus
    }
}

/// The guide beside System Settings (owner 10/5), only when Ask again can't bring macOS's question back. The checks
/// stand in a recorder.
struct ChromeAccessGuide {
    /// Opens the guide ("Turn this on." over DayDream's row with Chrome's switch flipping on).
    var show: () -> Void
    /// Access is on: a check, then the guide closes by itself and DayDream comes back to the front. Nothing if hidden.
    var done: () -> Void
    var hide: () -> Void

    static let silent = ChromeAccessGuide(show: {}, done: {}, hide: {})
    /// The app's panel. Silent unless this process is the DayDream .app (the command-line checks are not).
    static var live: ChromeAccessGuide {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return .silent }
        return ChromeAccessGuide(show: { MainActor.assumeIsolated { ChromeGuidePanel.show() } },
                                 done: { MainActor.assumeIsolated { ChromeGuidePanel.done() } },
                                 hide: { MainActor.assumeIsolated { ChromeGuidePanel.hide() } })
    }
}

/// The guide's panel: floating beside System Settings' window (it opens at Privacy & Security › Automation), never
/// taking focus from it. On done it shows a check, closes and brings DayDream back.
@MainActor enum ChromeGuidePanel {
    private static var panel: NSPanel?
    private static var host: NSHostingView<AnyView>?
    static let doneSeconds: TimeInterval = 1.4

    private final class Host: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    private static func view(_ step: ChromeGuideView.Step) -> AnyView {
        AnyView(ChromeGuideView(step: step, chromeIcon: ChromeReminderView.chromeIcon(), appIcon: NSApp.applicationIconImage,
                                close: { hide() }))
    }

    static func show() {
        let host = Host(rootView: view(.turnOn))
        let size = host.fittingSize
        let frame = NSRect(x: 0, y: 0, width: max(size.width, ChromeGuideView.width), height: size.height)
        let effect = NSVisualEffectView(frame: frame)
        effect.material = .popover; effect.state = .active; effect.blendingMode = .behindWindow
        effect.wantsLayer = true; effect.layer?.cornerRadius = 12; effect.layer?.masksToBounds = true
        host.frame = effect.bounds; host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        let window = panel ?? NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isFloatingPanel = true; window.level = .floating; window.hasShadow = true
        window.isOpaque = false; window.backgroundColor = .clear; window.ignoresMouseEvents = false
        window.becomesKeyOnlyIfNeeded = true; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        window.contentView = effect
        window.setContentSize(frame.size)
        panel = window; self.host = host
        place()
        window.orderFrontRegardless()
        NSAccessibility.post(element: host, notification: .announcementRequested,
                             userInfo: [.announcement: "In System Settings, under DayDream, turn on Google Chrome.",
                                        .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        // System Settings may still be opening: place it again once its window is there.
        for delay in [0.6, 1.5] { DispatchQueue.main.asyncAfter(deadline: .now() + delay) { if panel?.isVisible == true { place() } } }
    }

    static func done() {
        guard let panel, panel.isVisible, let host else { return }
        host.rootView = view(.done)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + doneSeconds) { hide() }
    }

    static func hide() { panel?.orderOut(nil) }

    private static func place() {
        guard let panel, let screen = NSScreen.main else { return }
        let origin = ChromeGuidePlacement.origin(guide: panel.frame.size, settings: settingsWindowFrame(), screen: screen.visibleFrame)
        panel.setFrameOrigin(origin)
    }

    /// System Settings' front window, in screen coordinates (window bounds need no permission; names aren't read).
    private static func settingsWindowFrame() -> NSRect? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first?.frame else { return nil }
        let bundleIDs: Set<String> = ["com.apple.systempreferences"]
        let pids = Set(NSWorkspace.shared.runningApplications.filter { bundleIDs.contains($0.bundleIdentifier ?? "") }.map(\.processIdentifier))
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pids.contains(pid),
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let w = bounds["Width"], let h = bounds["Height"], w > 200 else { continue }
            return NSRect(x: x, y: primary.height - y - h, width: w, height: h)
        }
        return nil
    }
}

/// Where the guide goes: right of System Settings' window, near its top (the Automation list), or left of it when the
/// right side has no room; without that window, the top right of the screen. Always inside the screen.
enum ChromeGuidePlacement {
    static let gap: CGFloat = 12
    static func origin(guide: NSSize, settings: NSRect?, screen: NSRect) -> NSPoint {
        var x: CGFloat, y: CGFloat
        if let settings {
            x = settings.maxX + gap + guide.width <= screen.maxX ? settings.maxX + gap : settings.minX - gap - guide.width
            y = settings.maxY - 64 - guide.height
        } else {
            x = screen.maxX - guide.width - 16
            y = screen.maxY - guide.height - 8
        }
        x = min(max(x, screen.minX + 8), screen.maxX - guide.width - 8)
        y = min(max(y, screen.minY + 8), screen.maxY - guide.height - 8)
        return NSPoint(x: x, y: y)
    }
}

/// The one in-app reminder (owner 10/5): the first time Chrome is used while its access is refused, a small calm panel
/// under the menu bar says "Chrome pages aren't being saved." with Ask again. It never takes focus from Chrome, closes by
/// itself, and is shown once ever (`ChromeAccessMemory.reminderKey`). The checks stand in a recorder.
struct ChromeAccessReminder {
    var show: (_ fix: @escaping () -> Void) -> Void
    var dismiss: () -> Void

    static let silent = ChromeAccessReminder(show: { _ in }, dismiss: {})
    /// The app's panel. Silent unless this process is the DayDream .app (the command-line checks are not).
    static var live: ChromeAccessReminder {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundleURL.pathExtension == "app" else { return .silent }
        return ChromeAccessReminder(show: { fix in MainActor.assumeIsolated { ChromeReminderPanel.show(fix: fix) } },
                                    dismiss: { MainActor.assumeIsolated { ChromeReminderPanel.hide() } })
    }
}

/// The reminder's panel: borderless, non-activating (Chrome keeps focus and keys), at the top right under the menu bar
/// like the typing pause toast, but it takes clicks: Ask again, and the close button.
@MainActor enum ChromeReminderPanel {
    private static var panel: NSPanel?
    private static var hideWork: DispatchWorkItem?
    static let seconds: TimeInterval = 15

    /// A first click on Fix acts at once, with Chrome still in front.
    private final class Host: NSHostingView<AnyView> {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }

    static func show(fix: @escaping () -> Void) {
        let view = ChromeReminderView(chromeIcon: ChromeReminderView.chromeIcon(), title: ChromeAccessNotice.askAgainTitle,
                                      fix: { hide(); fix() }, close: { hide() })
        let host = Host(rootView: AnyView(view))
        let size = host.fittingSize
        let frame = NSRect(x: 0, y: 0, width: max(size.width, ChromeReminderView.width), height: size.height)
        let effect = NSVisualEffectView(frame: frame)
        effect.material = .popover; effect.state = .active; effect.blendingMode = .behindWindow
        effect.wantsLayer = true; effect.layer?.cornerRadius = 12; effect.layer?.masksToBounds = true
        host.frame = effect.bounds; host.autoresizingMask = [.width, .height]
        effect.addSubview(host)
        let window = panel ?? NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        window.isFloatingPanel = true; window.level = .statusBar; window.hasShadow = true
        window.isOpaque = false; window.backgroundColor = .clear; window.ignoresMouseEvents = false
        window.becomesKeyOnlyIfNeeded = true; window.hidesOnDeactivate = false
        window.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle]
        window.contentView = effect
        window.setContentSize(frame.size)
        if let screen = NSScreen.main {
            let visible = screen.visibleFrame
            window.setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 16, y: visible.maxY - frame.height - 8))
        }
        window.orderFrontRegardless()
        NSAccessibility.post(element: host, notification: .announcementRequested,
                             userInfo: [.announcement: ChromeAccessNotice.line, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        panel = window
        hideWork?.cancel()
        let work = DispatchWorkItem { hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }

    static func hide() {
        hideWork?.cancel(); hideWork = nil
        panel?.orderOut(nil)
    }
}
